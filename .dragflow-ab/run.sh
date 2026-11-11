set -e
R=$(pwd); cd webviews; D=src/agent-session/acpmux
bunx tsc --noEmit -p tsconfig.json 2>&1 | tail -8 | sed "s/^/TSC /"; echo "TSC done"
bun test src/agent-session/acpmux 2>&1 | grep -E "^ *[0-9]+ (pass|fail)|^\(fail\)" | sed "s/^/UNIT /" || true
bun test test/agent-pane-*.test.ts 2>&1 | grep -E "^ *[0-9]+ (pass|fail)|^\(fail\)" | sed "s/^/PANE /" || true
base() { cp $R/.dragflow-ab/VT.base.tsx $D/VirtualTranscript.tsx; cp $R/.dragflow-ab/conv.base.css $D/conversation/conversation.css; }
fix() { cp $R/.dragflow-ab/VT.fix.tsx $D/VirtualTranscript.tsx; cp $R/.dragflow-ab/conv.fix.css $D/conversation/conversation.css; }
for pass in 1 2; do
  base; bun bench/transcript-resize-frame.bench.ts 100,1500 3 2>&1 | grep -E "drag#|rror" | sed "s/^/BASE$pass /" || true
  fix;  bun bench/transcript-resize-frame.bench.ts 100,1500 3 2>&1 | grep -E "drag#|rror" | sed "s/^/FIX$pass /" || true
done
