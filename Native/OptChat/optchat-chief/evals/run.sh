#!/usr/bin/env bash
# Chief fast evals: deterministic cases (tests/eval_*.rs) and model cases
# (evals/cases/*.json through examples/chief_eval.rs). Prints one table and
# writes artifacts under $OUT (default artifacts/chief-evals/<time>).
# Usage: run.sh [--only PREFIX] [--no-model] [--out DIR] [chief_eval flags...]
set -uo pipefail
ulimit -n 8192 2>/dev/null || ulimit -n "$(ulimit -Hn)"
cd "$(dirname "$0")/.."
out=${OUT:-$PWD/../../../artifacts/chief-evals/$(date -u +%Y%m%dT%H%M%SZ)}
model=1; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-model) model=0 ;;
    --out) out=${2:?--out needs a directory}; shift ;;
    *) args+=("$1") ;;
  esac
  shift
done
mkdir -p "$out"
status=0
tests=$(ls tests/eval_*.rs 2>/dev/null | sed -E 's#tests/(.*)\.rs#--test \1#')
if [ -n "$tests" ]; then
  echo "== deterministic cases"
  # shellcheck disable=SC2086
  cargo test -q $tests 2>&1 | tee "$out/deterministic.txt" | grep -E "^test |test result" || true
  grep -qE "test result: FAILED|error(\[|:)" "$out/deterministic.txt" && status=1
fi
if [ "$model" = 1 ]; then
  echo "== model cases"
  cargo build -q --example chief_eval || exit 2
  target=$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys;print(json.load(sys.stdin)["target_directory"])')
  "$target/debug/examples/chief_eval" --out "$out" "${args[@]}" || status=1
fi
exit $status
