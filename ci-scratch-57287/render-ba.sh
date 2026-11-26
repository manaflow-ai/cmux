#!/usr/bin/env bash
# Before/after render of #57287's five gallery states: after at the PR head, before with its three
# source files put back to the merge base (8ae19863) (tests unchanged; the states are what is judged).
set -uo pipefail
root=$(git rev-parse --show-toplevel)
states="agent-pane.subagent-report:long-report,agent-pane.subagent-report:report-hover,agent-pane.subagent-report:report-open,kit.primitives:tooltip-open,agent-pane.session-info-task-row-reason:tooltip"
cd "$root/webviews" && bun install --frozen-lockfile >/dev/null 2>&1
(cd "$root/scripts/gallery-matrix" && bun install --frozen-lockfile >/dev/null 2>&1)
"$root/scripts/ci/ensure-system-chrome.sh" >/dev/null 2>&1 || true
(cd "$root/scripts/gallery-matrix" && bunx playwright install --with-deps chromium >/tmp/pw.log 2>&1) || { tail -20 /tmp/pw.log; exit 4; }
entries=$(echo "$states" | tr ',' '\n' | cut -d: -f1 | sort -u | paste -sd,)
variants=$(echo "$states" | tr ',' '\n' | cut -d: -f2 | sort -u | paste -sd,)
render() {
  local out=${RUNNER_TEMP:-/tmp}/ghr-$1
  mkdir -p "$out"; cd "$root/webviews"
  bun scripts/gallery/manifest.ts --frame component --entries "$entries" --variants "$variants" --out "$out/manifest.json" || return 2
  local subset; subset="$(jq -r '[.[].params.entry // empty] | unique | join(",")' "$out/manifest.json")"
  CMUX_STRINGS_BEST_EFFORT=1 CMUX_GALLERY_ENTRIES="$subset" CMUX_GALLERY_OUT_DIR="$out/gallery" bun run gallery:build >"$out/build.log" 2>&1 || { tail -30 "$out/build.log"; return 3; }
  cd "$root/scripts/gallery-matrix"
  CMUX_GALLERY_IN_VM=1 bun health.ts --manifest "$out/manifest.json" --gallery-dir "$out/gallery" --output-dir "$out/health" --concurrency 4 --retries 0 >"$out/health.log" 2>&1
  echo "== $1: health exit $? over $(jq length "$out/manifest.json") renders"
  grep -v '^rendered' "$out/health.log" | grep -iE "broken|fail|threw|waitFor|cut|ok|pass|summary|total" | tail -25
}
render after
# The merge base's three source files, as the reverse of this PR's diff (no fetch on the runner).
git -C "$root" apply "$root/ci-scratch-57287/revert.patch" || { echo "revert patch failed"; exit 5; }
render before
