#!/usr/bin/env bash
# Fresh-Chief eval: a new person's Chief (clean home, default grant, no memory) walks the
# first-run steps; prints a pass-rate table. Runs anywhere cargo runs (minis, CI, cron).
# Usage: scripts-fresh-chief-eval.sh   (exit 1 when any step fails)
set -u
cd "$(dirname "$0")"
out=$(cargo test --test fresh_chief_placement --test fresh_chief_first_run 2>&1)
echo "$out" | grep -E "^test " | sed -E 's/^test //; s/ \.\.\. / | /'
pass=$(echo "$out" | grep -cE "^test .* ok$")
fail=$(echo "$out" | grep -cE "^test .* FAILED$")
echo "pass-rate: $pass/$((pass+fail))"
[ "$fail" -eq 0 ] && [ "$pass" -gt 0 ]
