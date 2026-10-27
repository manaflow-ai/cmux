#!/usr/bin/env bash
# B4 checks: tsgo, eslint, run unit tests, and next build route lists at base and head.
set -uo pipefail
if [ -z "${B4_COPIED:-}" ]; then cp "$0" /tmp/b4.sh; B4_COPIED=1 exec bash /tmp/b4.sh; fi
BASE=c584e7acc4e07ba917efb08e75a73f573f175817
if ! command -v bun >/dev/null; then curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.14" >/dev/null 2>&1; export PATH="$HOME/.bun/bin:$PATH"; fi
bun --version
cd "$(git rev-parse --show-toplevel)/web"
export RESEND_API_KEY=re_ci_build CMUX_FEEDBACK_FROM_EMAIL=ci@example.test STACK_SECRET_SERVER_KEY=ci-build-only \
  NEXT_PUBLIC_STACK_PROJECT_ID=00000000-0000-4000-8000-000000000000 NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY=ci-build-only \
  DATABASE_URL=postgres://cmux:cmux@127.0.0.1:1/cmux DIRECT_DATABASE_URL=postgres://cmux:cmux@127.0.0.1:1/cmux CMUX_ANALYTICS_TEST_MODE=1
bun install --frozen-lockfile >/dev/null 2>&1 || bun install --frozen-lockfile
rc=0
echo "=== HEAD $(git rev-parse HEAD)"
echo "=== tsgo"; bun run typecheck || rc=1
echo "=== eslint (changed files)"; bunx eslint app/api/runs app/api/cron/runs services/runs scripts/cloud-vm/run-admission-probe.ts tests/runs-*.test.ts tests/sourceVerification.test.ts tests/cloud-vm-run-fanout.test.ts || rc=1
echo "=== run tests"; bun test tests/runs-*.test.ts tests/sourceVerification.test.ts tests/cloud-vm-run-fanout.test.ts || rc=1
(cd .. && python3 tests/test_ci_no_shallow_dev_fetch.py) || rc=1
routes() { # $1 = label
  echo "=== next build ($1)"
  rm -rf .next
  VERCEL_PREVIEW_COMMENTS_ENABLED=0 bunx next build > "/tmp/build-$1.log" 2>&1; local s=$?
  tail -5 "/tmp/build-$1.log"; [ $s -eq 0 ] || { echo "build $1 failed"; cat "/tmp/build-$1.log" | tail -60; rc=1; }
  for m in .next/server/app-paths-manifest.json .next/app-path-routes-manifest.json .next/routes-manifest.json; do
    [ -f "$m" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d if not isinstance(d,dict) or "version" not in d else {k:d[k] for k in ("staticRoutes","dynamicRoutes") if k in d}, sort_keys=True, indent=1))' "$m" > "/tmp/$1-$(basename $m)"
  done
  sed -n '/^Route (app)/,$p' "/tmp/build-$1.log" | sed -E 's/[0-9.]+ ?(k?B|ms|s)\b//g; s/ +$//' > "/tmp/$1-table.txt"
}
bun tools/sync-changelog.ts >/dev/null && bun tools/generate-managed-iroh-relay-catalog.ts --check >/dev/null && bun tools/build-docs-search.mjs >/dev/null
routes head
echo "=== Run route lines at head"; grep -E "/api/(cron/)?runs" /tmp/head-table.txt
git cat-file -e "$BASE^{commit}" 2>/dev/null || git fetch -q https://github.com/manaflow-ai/cmux.git "$BASE" || git fetch -q origin "$BASE"; git -c advice.detachedHead=false checkout -q "$BASE" || { echo "cannot check out base"; exit 1; }
echo "=== BASE $(git rev-parse HEAD)"; ls services/runs
routes base
echo "=== route diffs (empty means identical)"
for f in app-paths-manifest.json app-path-routes-manifest.json routes-manifest.json table.txt; do
  if [ -f "/tmp/head-$f" ]; then echo "--- $f: $(wc -l < /tmp/head-$f) lines"; diff "/tmp/base-$f" "/tmp/head-$f" && echo "identical"; fi
done
sha256sum /tmp/base-app-paths-manifest.json /tmp/head-app-paths-manifest.json
exit $rc
