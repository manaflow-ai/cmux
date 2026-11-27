#!/usr/bin/env bash
# Lane A CI script (not committed): tests at head and at base, typecheck, gallery before/after.
set -u
cd webviews
FILES="src/agent-session/acpmux/conversation/ test/working-header-label.test.tsx test/turn-header-one-row.test.tsx"
CHANGED="src/agent-session/acpmux/conversation/turns.ts src/agent-session/acpmux/conversation/waterfallSpans.ts src/agent-session/acpmux/conversation/QuickSubagentTurn.gallery.ts src/agent-session/acpmux/conversation/TurnFooter.test.tsx src/agent-session/acpmux/conversation/TurnTokens.tsx src/agent-session/acpmux/conversation/WorkingFor.tsx src/agent-session/acpmux/conversation/zeroToolCalls.test.ts test/working-header-label.test.tsx test/turn-header-one-row.test.tsx"
bun test $FILES >/tmp/test-head.log 2>&1; HEAD_EXIT=$?
grep '(fail)' /tmp/test-head.log | sed 's/ \[[0-9.]*ms\]$//' | sort -u > /tmp/fail-head.txt
echo "HEAD_TEST_EXIT=$HEAD_EXIT"; grep -E '^ *[0-9]+ (pass|fail)' /tmp/test-head.log
NODE_OPTIONS=--max-old-space-size=12288 bunx tsc -p . --noEmit >/tmp/tsc.log 2>&1; TSC=$?; echo "TSC_RESULT=$TSC"; grep -E 'error TS' /tmp/tsc.log | head -30
OUT=${FAST_CHECKS_OUT:-/tmp/artifacts}/gallery; mkdir -p "$OUT"
capture() {
  rm -rf dist/gallery
  bun run gallery:build >/tmp/gallery-$1.log 2>&1 || { echo "GALLERY_BUILD_FAIL $1"; tail -20 /tmp/gallery-$1.log; return; }
  bun scripts/gallery/manifest.ts --entries "$ENTRIES" --themes pair --locales en --frame component --widths normal --out /tmp/manifest-$1.json 2>/tmp/manifest-$1.err || tail -5 /tmp/manifest-$1.err
  (cd ../scripts/gallery-matrix && bun install >/dev/null 2>&1; bunx playwright install webkit >/dev/null 2>&1; ../ci/ensure-system-chrome.sh >/dev/null 2>&1; CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest /tmp/manifest-$1.json --gallery-dir ../../webviews/dist/gallery --output-dir "$OUT/$1" 2>&1 | tail -8)
}
ENTRIES=agent-pane.worked-for-wall-span,agent-pane.quick-subagent-turn
capture after
BASE=833dba8999d7edd4d6e54afb77dc69b8dd0e749e
git cat-file -e $BASE 2>/dev/null || git fetch -q --depth=1 origin $BASE
git checkout $BASE -- $CHANGED; echo "BASE_DIFF_FILES=$(git diff --name-only HEAD | wc -l)"
mv src/agent-session/acpmux/conversation/workedWallSpan.test.ts /tmp/workedWallSpan.test.ts
bun test $FILES >/tmp/test-base.log 2>&1; echo "BASE_TEST_EXIT=$?"
grep '(fail)' /tmp/test-base.log | sed 's/ \[[0-9.]*ms\]$//' | sort -u > /tmp/fail-base.txt
echo "== failing at head, not at base (this lane's):"; comm -23 /tmp/fail-head.txt /tmp/fail-base.txt
echo "== failing at both (base's):"; comm -12 /tmp/fail-head.txt /tmp/fail-base.txt | wc -l
capture before
mv /tmp/workedWallSpan.test.ts src/agent-session/acpmux/conversation/workedWallSpan.test.ts
git checkout HEAD -- $CHANGED
cp /tmp/test-head.log /tmp/test-base.log /tmp/fail-head.txt /tmp/fail-base.txt /tmp/tsc.log "$OUT/" 2>/dev/null
find "$OUT" -name '*.png' | head -40
NEW=$(comm -23 /tmp/fail-head.txt /tmp/fail-base.txt | wc -l)
s=0; [ "$NEW" -eq 0 ] || s=1; [ "$TSC" -eq 0 ] || s=1
exit $s
