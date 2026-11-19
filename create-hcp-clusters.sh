#!/usr/bin/env bash
# Batch-create ROSA HCP clusters: VPC (one terraform workspace per cluster) -> OIDC config -> KMS key -> cluster.
# Env overrides: REGION, AWS_PROFILE, CIDR_START_OCTET
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="${REGION:-us-gov-west-1}"
export AWS_PROFILE="${AWS_PROFILE:-fedramp-devtest}"
CIDR_START_OCTET="${CIDR_START_OCTET:-2}"
SUBNET_AZS="[\"${REGION}a\", \"${REGION}b\", \"${REGION}c\"]"
SUMMARY_FILE="$SCRIPT_DIR/hcp-clusters-summary.txt"

NAME_RE='^[a-z][-a-z0-9]{0,13}[a-z0-9]$'
ACCOUNT_RE='^[0-9]{12}$'
ROLE_RE='^arn:aws[-a-z]*:iam::[0-9]{12}:role/.+'

tf() { terraform -chdir="$SCRIPT_DIR" "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n==> [%s] %s\n' "$1" "$2"; }

# prompt VAR LABEL [DEFAULT] [REQUIRED=1] [REGEX] [HINT]
prompt() {
  local __var=$1 __label=$2 __def=${3:-} __req=${4:-1} __re=${5:-} __hint=${6:-} __in
  while :; do
    if [[ -n $__def ]]; then
      read -r -p "  $__label [$__def]: " __in
      __in=${__in:-$__def}
    else
      read -r -p "  $__label: " __in
    fi
    [[ $__in == none ]] && __in=""
    if [[ -z $__in ]]; then
      [[ $__req == 0 ]] && break
      echo "    (required)"
    elif [[ -n $__re && ! $__in =~ $__re ]]; then
      echo "    invalid: $__hint"
      __def=""
    else
      break
    fi
  done
  printf -v "$__var" '%s' "$__in"
}

prompt_name() {
  local __var=$1 __n
  while :; do
    prompt __n "Cluster name" "" 1 "$NAME_RE" "2-15 chars, lowercase alphanumeric/hyphens, must start with a letter"
    if [[ " ${NAMES[*]:-} " == *" $__n "* ]]; then
      echo "    already used in this batch"
    elif tf workspace list | sed 's/^[* ]*//' | grep -qx "$__n"; then
      echo "    terraform workspace '$__n' already exists (leftover from a previous run?)"
    elif rosa describe cluster -c "$__n" --profile "$AWS_PROFILE" >/dev/null 2>&1; then
      echo "    cluster '$__n' already exists"
    else
      break
    fi
  done
  printf -v "$__var" '%s' "$__n"
}

# Second octets of every 10.x.x.x CIDR on any VPC in the region.
used_octets() {
  aws ec2 describe-vpcs --region "$REGION" \
    --query 'Vpcs[].CidrBlockAssociationSet[].CidrBlock' --output text |
    tr '\t' '\n' | awk -F. '$1 == 10 { print $2 }' | sort -un
}

create_one() {
  local name=${NAMES[$1]} cidr=${CIDRS[$1]} plan="$SCRIPT_DIR/${NAMES[$1]}.tfplan" oidc_json
  R_SUBNETS="" R_OIDC="" R_KMS=""

  step "$name" "Creating VPC $cidr (terraform workspace '$name')"
  tf workspace new "$name" >/dev/null || return 1
  tf plan -input=false -out "$plan" \
    -var region="$REGION" \
    -var "subnet_azs=$SUBNET_AZS" \
    -var cluster_name="$name" \
    -var vpc_cidr="$cidr" \
    -var subnet_cidr_prefix=24 \
    -var private_subnets_only=false \
    -var single_az_only=false || return 1
  tf apply -input=false "$plan" || return 1
  rm -f "$plan"
  R_SUBNETS=$(tf output -raw cluster-subnets-string) || return 1

  step "$name" "Creating managed OIDC config"
  oidc_json=$(rosa create oidc-config --mode auto --managed --profile "$AWS_PROFILE" --yes -o json) || return 1
  R_OIDC=$(jq -r '.id // empty' <<<"$oidc_json" 2>/dev/null)
  [[ -n $R_OIDC ]] || { echo "Could not parse OIDC config id from: $oidc_json" >&2; return 1; }
  echo "OIDC config id: $R_OIDC"

  step "$name" "Creating KMS key"
  R_KMS=$(aws kms create-key --region "$REGION" \
    --description "$name ROSA Encryption Key" \
    --tags TagKey=red-hat,TagValue=true \
    --query KeyMetadata.Arn --output text) || return 1
  echo "KMS key: $R_KMS"

  step "$name" "Creating cluster (OCP ${VERSIONS[$1]}, channel ${CHANNELS[$1]})"
  local args=(create cluster
    --cluster-name "$name"
    --hosted-cp
    --version "${VERSIONS[$1]}"
    --sts
    --oidc-config-id "$R_OIDC"
    --subnet-ids "$R_SUBNETS"
    --region "$REGION"
    --mode auto
    --etcd-encryption-kms-arn "$R_KMS"
    --yes
    --machine-cidr "$cidr"
    --channel-group "${CHANNELS[$1]}"
    --billing-account "${BILLINGS[$1]}"
    --profile "$AWS_PROFILE")
  [[ -n ${SUPPORT_ROLES[$1]} ]] && args+=(--support-role-arn "${SUPPORT_ROLES[$1]}")
  [[ -n ${WORKER_ROLES[$1]} ]] && args+=(--worker-iam-role "${WORKER_ROLES[$1]}")
  rosa "${args[@]}"
}

# --- preflight ---
for cmd in terraform rosa aws jq; do
  command -v "$cmd" >/dev/null || die "$cmd not found in PATH"
done
echo "Region: $REGION | AWS profile: $AWS_PROFILE"
aws sts get-caller-identity --query Account --output text >/dev/null || die "AWS credentials for profile '$AWS_PROFILE' are not working"
rosa whoami --profile "$AWS_PROFILE" >/dev/null 2>&1 || die "rosa is not logged in (run rosa login)"
init_out=$(tf init -input=false 2>&1) || { echo "$init_out"; die "terraform init failed"; }

# --- collect input ---
while :; do
  read -r -p "How many clusters do you want to create? " COUNT
  [[ $COUNT =~ ^[1-9][0-9]*$ ]] && break
done

NAMES=() VERSIONS=() CHANNELS=() BILLINGS=() SUPPORT_ROLES=() WORKER_ROLES=() CIDRS=()
version="" channel="stable" billing="" support="" worker=""
for ((i = 0; i < COUNT; i++)); do
  printf '\nCluster %d of %d  (Enter keeps the [default]; type "none" to clear an optional value)\n' $((i + 1)) "$COUNT"
  prompt_name name
  prompt version "OCP version" "$version" 1 '^[0-9]+\.[0-9]+\.[0-9]+.*$' "e.g. 4.18.12"
  prompt channel "Channel group" "$channel"
  prompt billing "Billing account ID" "$billing" 1 "$ACCOUNT_RE" "12-digit AWS account ID"
  prompt support "Support role ARN (optional)" "$support" 0 "$ROLE_RE" "IAM role ARN"
  prompt worker "Worker role ARN (optional)" "$worker" 0 "$ROLE_RE" "IAM role ARN"
  NAMES+=("$name") VERSIONS+=("$version") CHANNELS+=("$channel") BILLINGS+=("$billing")
  SUPPORT_ROLES+=("$support") WORKER_ROLES+=("$worker")
done

# --- allocate CIDRs ---
used=" $(used_octets | tr '\n' ' ') " || die "could not list existing VPCs"
next=$CIDR_START_OCTET
for ((i = 0; i < COUNT; i++)); do
  while [[ $used == *" $next "* ]]; do ((next++)); done
  ((next <= 255)) || die "no free 10.x.0.0/16 CIDRs left"
  CIDRS+=("10.$next.0.0/16")
  ((next++))
done

# --- confirm ---
printf '\n%-16s %-14s %-10s %-14s %-14s %-8s %s\n' NAME VERSION CHANNEL BILLING CIDR SUPPORT WORKER
for ((i = 0; i < COUNT; i++)); do
  printf '%-16s %-14s %-10s %-14s %-14s %-8s %s\n' "${NAMES[$i]}" "${VERSIONS[$i]}" "${CHANNELS[$i]}" \
    "${BILLINGS[$i]}" "${CIDRS[$i]}" "${SUPPORT_ROLES[$i]:+yes}" "${WORKER_ROLES[$i]:+yes}"
done
read -r -p $'\nProceed? [y/N] ' ok
[[ $ok =~ ^[Yy]$ ]] || exit 0

trap 'tf workspace select default >/dev/null 2>&1' EXIT

# --- create ---
FAILED=()
for ((i = 0; i < COUNT; i++)); do
  if create_one "$i"; then status=OK; else status=FAILED; FAILED+=("${NAMES[$i]}"); fi
  printf '%s %s name=%s version=%s channel=%s cidr=%s workspace=%s oidc=%s kms=%s subnets=%s\n' \
    "$(date -u +%FT%TZ)" "$status" "${NAMES[$i]}" "${VERSIONS[$i]}" "${CHANNELS[$i]}" "${CIDRS[$i]}" \
    "${NAMES[$i]}" "${R_OIDC:--}" "${R_KMS:--}" "${R_SUBNETS:--}" >>"$SUMMARY_FILE"
done

echo
echo "Done. Details appended to $SUMMARY_FILE"
if ((${#FAILED[@]})); then
  echo "FAILED: ${FAILED[*]} (any partially created resources are listed in the summary file)"
  exit 1
fi
echo "Watch installs with: rosa logs install -c <name> --watch"
