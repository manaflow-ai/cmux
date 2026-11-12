set -u
cd webviews
T="test/transcript-cohesion.test.ts test/turn-end-fold-browser.test.ts test/agent-pane-bottom-stack.test.ts test/transcript-row-word-lift-browser.test.ts test/transcript-spacing-kinds.test.ts test/agent-pane-transcript-view.test.ts"
for t in $T; do echo "=== HEAD $t"; timeout 400 bun test $t 2>&1 | grep -E "^\(fail\)|^ *[0-9]+ (pass|fail)|error:" | head -12; done
cd .. && git apply -R .landsweep/src.patch && echo REVERTED && cd webviews
for t in $T; do echo "=== BASE $t"; timeout 400 bun test $t 2>&1 | grep -E "^\(fail\)|^ *[0-9]+ (pass|fail)|error:" | head -12; done
