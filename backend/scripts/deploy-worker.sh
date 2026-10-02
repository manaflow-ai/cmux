#!/usr/bin/env bash
# Deploys the API Worker to one environment: development | staging | preview-<n>.
# Production is refused here until the coordinator approves it.
# Local runs use the cf CLI's OAuth token; CI passes CLOUDFLARE_API_TOKEN.
set -euo pipefail
target="${1:?usage: deploy-worker.sh development|staging|preview-<pr>}"
cd "$(dirname "$0")/../apps/api"
export CLOUDFLARE_ACCOUNT_ID=0c1675e0def6de1ab3a50a4e17dc5656
if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  cf auth whoami >/dev/null
  CLOUDFLARE_API_TOKEN="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/Library/Preferences/cloudflare/config/default.json')))['oauth_token'])")"
  export CLOUDFLARE_API_TOKEN
fi
case "$target" in
  production) echo "production deploys need the coordinator's approval; refusing" >&2; exit 2 ;;
  development|staging) env_name="$target"; extra=() ;;
  preview-*) env_name="staging"; extra=(--name "cmux-api-${target}") ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac
umask 077
secrets="$(mktemp "${TMPDIR:-/tmp}/cmux-api-secrets.XXXXXX")"
trap 'rm -f "$secrets"' EXIT
secret_file="$HOME/.secrets/cmux-next-api-${env_name}.env"
if [ -n "${JWT_PRIVATE_JWK:-}" ]; then
  printf '{"JWT_PRIVATE_JWK":%s}\n' "$(python3 -c 'import json,os;print(json.dumps(os.environ["JWT_PRIVATE_JWK"]))')" > "$secrets"
elif [ -f "$secret_file" ]; then
  python3 - "$secret_file" > "$secrets" <<'PY'
import json, sys
vals = dict(l.split("=", 1) for l in open(sys.argv[1]).read().splitlines() if "=" in l)
print(json.dumps({"JWT_PRIVATE_JWK": vals["JWT_PRIVATE_JWK"]}))
PY
else
  echo "no JWT_PRIVATE_JWK for $env_name" >&2; exit 1
fi
./node_modules/.bin/wrangler deploy --env "$env_name" "${extra[@]}" --secrets-file "$secrets"
