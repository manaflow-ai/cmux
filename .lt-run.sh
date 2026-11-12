set -u
cd webviews
echo "== typecheck"; bun run typecheck 2>&1 | tail -3
T=$(ls test/thread-minimap-*.test.* test/thread-rail-*.test.* test/thread-scroll-map-rail.test.tsx test/thread-bookmarks.test.tsx test/jump-scroll-animation.test.ts test/transcript-fling.test.ts test/transcript-upward-anchor.test.ts test/transcript-jump-latest.test.ts test/transcript-long-chat-updates.test.ts test/agent-pane-soft-edges.test.ts 2>/dev/null)
for t in $T; do echo "== $t"; bun test $t 2>&1 | grep -E "^\(fail\)| pass$| fail$|Expected|Received" | head -8; done
echo "== conversation"; bun test src/agent-session/acpmux/conversation src/agent-session/acpmux/threadMinimap 2>&1 | grep -E "^\(fail\)| pass$| fail$" | head
bench() { for i in 1 2 3; do WHY=1 ENGINES=webkit,chromium TURNS=600 bun bench/transcript-scroll-up.bench.ts 2>&1 | grep -E " why (scroll|landing) \(|scrollP95|landingP95|longTask" ; done; }
trace() { TRACE=1 ENGINES=chromium TURNS=600 bun bench/transcript-scroll-up.bench.ts 2>&1 | grep -E "longTask|landingP95|trace task" | head -12; }
echo "== AFTER"; bench; echo "== AFTER trace"; trace
cp src/agent-session/acpmux/VirtualTranscript.tsx /tmp/vt.keep; cp src/agent-session/acpmux/threadMinimap/ThreadMinimap.tsx /tmp/tm.keep
cp ../.lt-base/VirtualTranscript.tsx src/agent-session/acpmux/VirtualTranscript.tsx; cp ../.lt-base/ThreadMinimap.tsx src/agent-session/acpmux/threadMinimap/ThreadMinimap.tsx
echo "== BEFORE"; bench; echo "== BEFORE trace"; trace
cp /tmp/vt.keep src/agent-session/acpmux/VirtualTranscript.tsx; cp /tmp/tm.keep src/agent-session/acpmux/threadMinimap/ThreadMinimap.tsx
