#!/usr/bin/env bash
# Fresh-Chief eval: a new person's Chief (clean home, default grant, no memory) walks the
# first-run steps; prints a pass-rate table. Runs anywhere cargo runs (minis, CI, cron).
# Usage: scripts-fresh-chief-eval.sh   (exit 1 when any step fails)
set -u
cd "$(dirname "$0")"
out=$(cargo test --test fresh_chief_placement --test fresh_chief_first_run 2>&1)
# Hosted (Cloud) Chief case, a655: a spawned child gets a workspace link (needs backend deps; skipped without).
api=../../../backend/apps/api
if [ -d "$api/node_modules" ] || [ -d ../../../backend/node_modules ]; then
  hosted=$(cd "$api" && bun x vitest run test/chief-brain-spawn-workspace.test.ts --reporter=verbose 2>&1)
  out="$out
$(echo "$hosted" | sed -nE 's/^ *[✓√] .*> (.*) [0-9]+ms$/test hosted: \1 ... ok/p; s/^ *[×✗] .*> (.*) [0-9]+ms$/test hosted: \1 ... FAILED/p')"
fi
echo "$out" | grep -E "^test " | sed -E 's/^test //; s/ \.\.\. / | /'
pass=$(echo "$out" | grep -cE "^test .* ok$")
fail=$(echo "$out" | grep -cE "^test .* FAILED$")
echo "pass-rate: $pass/$((pass+fail))"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
