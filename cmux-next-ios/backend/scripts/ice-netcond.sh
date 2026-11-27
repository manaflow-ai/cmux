#!/usr/bin/env bash
# Run from the backend after bun install --frozen-lockfile. BASE is the unmodified PR base.
set -euo pipefail
base=${1:?usage: bash scripts/ice-netcond.sh BASE}
backend=$(cd "$(dirname "$0")/.." && pwd)
# Fast checks may have a shallow checkout containing only the tested tip.
if ! git -C "$backend" cat-file -e "$base^{commit}" 2>/dev/null; then
  depth=()
  [[ "$(git -C "$backend" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth=1)
  git -C "$backend" fetch --no-tags ${depth[@]+"${depth[@]}"} origin "$base"
fi
repo=$(git -C "$backend" rev-parse --show-toplevel)
scratch=$(mktemp -d)
trap 'rm -r -- "$scratch"' EXIT
for phase in before after; do
  ref=$base
  if [[ $phase == after ]]; then ref=HEAD; fi
  dir="$scratch/$phase"
  mkdir "$dir"
  git -C "$repo" archive "$ref:cmux-next-ios/backend" | tar -x -C "$dir"
  ln -s "$backend/node_modules" "$dir/node_modules"
  cp "$backend/scripts/ice-netcond.ts" "$dir/test/ice-$phase.test.ts"
  (
    cd "$dir"
    "$backend/node_modules/.bin/vitest" run "test/ice-$phase.test.ts"
  )
done
