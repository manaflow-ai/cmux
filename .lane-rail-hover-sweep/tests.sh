#!/bin/bash
# Scratch for lane rail-hover-sweep (not committed): red on the test commit, green at HEAD, rail suites.
set -uo pipefail
cd "$(dirname "$0")/../webviews"
bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null
git remote get-url origin >/dev/null 2>&1 || git remote add origin https://github.com/manaflow-ai/cmux.git
echo "== RED (fix reverted)"; (cd .. && git apply -R .lane-rail-hover-sweep/fix.patch) && bun test test/thread-minimap-rail.test.tsx -t "sweeping the pointer" 2>&1 | tail -12; bun test test/stylesheets.test.ts 2>&1 | tail -12; git checkout -- src
echo "== GREEN jsdom"; bun test test/thread-minimap-*.test.ts* test/thread-rail-*.test.ts test/hover-intent-cards.test.tsx test/stylesheets.test.ts $(ls test | grep -iE "fold|running-tray|subagent-tray|tray" | sed "s#^#test/#" | tr "\n" " ") test/minimap-*.test.ts test/chat-minimap*.test.ts* src/agent-session/acpmux/threadMinimap/useRailPlacement.dom.test.tsx 2>&1 | grep -E "^\(fail\)|pass$|fail$| pass| fail|Ran " | tail -30
echo "== GREEN browser"; CI=1 CMUX_BROWSER_TESTS=1 bun test test/thread-minimap-feel.test.ts test/thread-minimap-motion.test.ts test/thread-minimap-tick-states.test.ts test/thread-minimap-left-rail-stays.test.ts test/thread-minimap-side.test.tsx test/thread-minimap-flash.test.ts test/thread-rail-scroll-entrance.test.ts test/preview-card-placement.test.ts test/minimap-card-layout.test.ts test/thread-minimap-card-glass.test.ts 2>&1 | grep -E "^\(fail\)| pass| fail|Ran |error:" | tail -30
echo "== lint"; bunx vp fmt --check $(git diff --name-only 584b3f6abd39 -- . | sed 's#^webviews/##') 2>&1 | tail -5; bunx vp lint $(git diff --name-only 584b3f6abd39 -- . | sed 's#^webviews/##') 2>&1 | tail -8
