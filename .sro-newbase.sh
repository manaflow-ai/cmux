#!/bin/bash
git apply -R .sro-fix.patch && echo "BASE-APPLIED"
cd webviews
T="test/transcript-block-sideways-scrollbar.test.ts test/agent-pane-reveal-in-place.test.ts"
for i in 1 2; do for t in $T; do echo "### base$i $t"; bun test $t 2>&1 | grep -E "^\(fail\)| pass$| fail$" | head -12; done; done
