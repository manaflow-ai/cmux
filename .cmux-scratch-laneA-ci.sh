#!/usr/bin/env bash
# Lane A CI script (not committed): base-red dedupe (#60222's), tests, typecheck, gallery before/after.
set -u
cd webviews
bun install --frozen-lockfile >/tmp/install.log 2>&1; echo INSTALL_EXIT=$?; tail -5 /tmp/install.log
bun test src/agent-session/acpmux/conversation/ test/working-header-label.test.tsx test/turn-header-one-row.test.tsx >/tmp/test.log 2>&1; echo TEST_EXIT=$?
grep -E '\(fail\)|^ *[0-9]+ (pass|fail)|error:' /tmp/test.log | head -60
bunx tsc -p . --noEmit >/tmp/tsc.log 2>&1; echo TSC_EXIT=$?; head -30 /tmp/tsc.log
OUT=${FAST_CHECKS_OUT:-/tmp/artifacts}/gallery; mkdir -p "$OUT"
capture() { # $1 = label
  rm -rf dist/gallery
  bun run gallery:build >/tmp/gallery-$1.log 2>&1 || { echo "GALLERY_BUILD_FAIL $1"; tail -20 /tmp/gallery-$1.log; return; }
  bun scripts/gallery/manifest.ts --entries "$ENTRIES" --themes pair --locales en --frame component --widths normal --out /tmp/manifest-$1.json 2>/tmp/manifest-$1.err || { cat /tmp/manifest-$1.err | tail -5; }
  (cd ../scripts/gallery-matrix && bun install >/dev/null 2>&1; bunx playwright install webkit >/dev/null 2>&1; ../ci/ensure-system-chrome.sh >/dev/null 2>&1; CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest /tmp/manifest-$1.json --gallery-dir ../../webviews/dist/gallery --output-dir "$OUT/$1" 2>&1 | tail -8)
}
ENTRIES=agent-pane.worked-for-wall-span,agent-pane.quick-subagent-turn
capture after
# Before: the base's turns.ts/waterfallSpans.ts and siblings, same gallery entry file.
git stash push -q -- src/agent-session/acpmux/conversation/turns.ts src/agent-session/acpmux/conversation/waterfallSpans.ts src/agent-session/acpmux/conversation/QuickSubagentTurn.gallery.ts
capture before
git stash pop -q
find "$OUT" -name '*.png' | head -40
