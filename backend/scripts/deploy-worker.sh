#!/usr/bin/env bash
# Deploys the API Worker to one environment: development | staging | production | preview-<n>.
# Production also needs CMUX_NEXT_DEPLOY_PRODUCTION=1 (CI sets it in the gated production job)
# and refuses to deploy while any migration in db/migrations is not applied to production.
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
  production)
    [ "${CMUX_NEXT_DEPLOY_PRODUCTION:-}" = 1 ] || { echo "set CMUX_NEXT_DEPLOY_PRODUCTION=1 to deploy production" >&2; exit 2; }
    env_name=production; extra=() ;;
  development|staging) env_name="$target"; extra=() ;;
  # Previews bind the development Hyperdrive and Stack dev project (spec: previews reuse
  # development); DO state is isolated by the Worker name.
  preview-*) env_name="development"; extra=(--name "cmux-api-${target}") ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac
umask 077
secrets="$(mktemp "${TMPDIR:-/tmp}/cmux-api-secrets.XXXXXX")"
trap 'rm -f "$secrets"' EXIT
secret_file="$HOME/.secrets/cmux-next-api-${env_name}.env"
case "$target" in preview-*) secret_file="$HOME/.secrets/cmux-next-api-preview.env" ;; esac
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
# Merging deploys: code ships only onto a schema that already has every migration.
if [ "$env_name" = staging ] || [ "$env_name" = production ]; then
  (cd ../../db && bun migrate.ts --env "$env_name" --verify)
fi
# Workflow names are account-wide: a preview gets its own (`cmux-automation-run-preview-<n>`)
# instead of taking over development's. The generated config sits next to the real one so
# relative paths still resolve; it is removed on exit.
config=(--config wrangler.jsonc)
case "$target" in
  preview-*)
    preview_config="wrangler.${target}.generated.jsonc"
    trap 'rm -f "$secrets" "$preview_config"' EXIT
    sed "s/\"cmux-automation-run-development\"/\"cmux-automation-run-${target}\"/" wrangler.jsonc > "$preview_config"
    grep -q "cmux-automation-run-${target}" "$preview_config" || { echo "preview workflow rename failed" >&2; exit 1; }
    config=(--config "$preview_config") ;;
esac
# Release rails (plans/cmux-next/release-rails.md): staging and production record the serving
# version, deploy, smoke ../release-smoke.json (health + routes whose sources changed since
# CMUX_RELEASE_CHANGED_SINCE) and run `wrangler rollback` to the recorded version on red.
rails="../../../scripts/cmux-next/release/worker-release.ts"
case "$env_name" in
  staging) worker=cmux-api-staging; origin=https://cloud-api-staging.cmux.dev ;;
  production) worker=cmux-api; origin=https://cloud-api.cmux.dev ;;
  *) worker="" ;;
esac
case "$target" in preview-*) worker="" ;; esac
if [ -n "$worker" ]; then
  previous="$(mktemp "${TMPDIR:-/tmp}/cmux-api-previous.XXXXXX")"
  trap 'rm -f "$secrets" "$previous"' EXIT
  bun "$rails" previous --worker "$worker" --wrangler ./node_modules/.bin/wrangler --out "$previous"
fi
./node_modules/.bin/wrangler deploy "${config[@]}" --env "$env_name" "${extra[@]}" --secrets-file "$secrets"
if [ -n "$worker" ]; then
  bun "$rails" verify --worker "$worker" --url "$origin" --routes release-smoke.json --previous-file "$previous" \
    --changed-since "${CMUX_RELEASE_CHANGED_SINCE:-}" --source-dir . --wrangler ./node_modules/.bin/wrangler
fi
