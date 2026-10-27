#!/usr/bin/env bash
set -uo pipefail
if [ -z "${B4_COPIED:-}" ]; then cp "$0" /tmp/b4b.sh; B4_COPIED=1 exec bash /tmp/b4b.sh; fi
BASE=c584e7acc4e07ba917efb08e75a73f573f175817
command -v bun >/dev/null || { curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.14" >/dev/null 2>&1; export PATH="$HOME/.bun/bin:$PATH"; }
cd "$(git rev-parse --show-toplevel)"
git cat-file -e "$BASE^{commit}" 2>/dev/null || git fetch -q https://github.com/manaflow-ai/cmux.git "$BASE"
git -c advice.detachedHead=false checkout -q "$BASE"; echo "=== BASE $(git rev-parse HEAD)"
cd web; bun install --frozen-lockfile >/dev/null 2>&1
echo "=== eslint base"; bunx eslint app/api/runs app/api/cron/runs services/runs scripts/cloud-vm/run-admission-probe.ts tests/runs-*.test.ts tests/sourceVerification.test.ts tests/cloud-vm-run-fanout.test.ts 2>&1 | grep -E "^/|problems"
echo "=== combined bun test base"; bun test tests/runs-*.test.ts tests/sourceVerification.test.ts tests/cloud-vm-run-fanout.test.ts 2>&1 | grep -E "^ *[0-9]+ (pass|fail|error)|isStackConfigured|^Ran"
echo "=== per-file bun test base"; for f in tests/runs-*.test.ts tests/sourceVerification.test.ts tests/cloud-vm-run-fanout.test.ts; do bun test "$f" >/tmp/o 2>&1; echo "$f exit=$?"; done
git -c advice.detachedHead=false checkout -q -; echo "=== HEAD $(git rev-parse HEAD)"; echo "=== per-file bun test head"; for f in tests/runs-*.test.ts tests/sourceVerification.test.ts tests/cloud-vm-run-fanout.test.ts; do bun test "$f" >/tmp/o 2>&1; echo "$f exit=$?"; done
