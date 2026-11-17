#!/bin/bash
# Scratch (not committed): test the #44387 fix on its own head, without the follow-up's edits.
set -u
mkdir -p /tmp/fx && cp .olc-fix-rmm.ts /tmp/fx/rmm.ts && cp .olc-fix-revealClock.test.ts /tmp/fx/revealClock.test.ts
git apply -R .olc-wip.patch || { echo NOREVERT; exit 3; }; xargs -r rm -f < .olc-wip-new.txt; git status --short | grep -v "^?? .olc" | head
echo "AT $(git rev-parse HEAD)"
D=webviews/src/agent-session/acpmux/conversation
cp /tmp/fx/revealClock.test.ts $D/revealClock.test.ts
echo "##### red (54d9d45 source)"
(cd webviews && bun test src/agent-session/acpmux/conversation/revealClock.test.ts 2>&1 | grep -E "\(fail\)|\(pass\)| pass$| fail$")
cp /tmp/fx/rmm.ts $D/revealedMarkdownModel.ts
echo "##### green (fixed source)"
(cd webviews && bun test src/agent-session/acpmux/conversation/ src/agent-session/acpmux/chips/ src/agent-session/acpmux/layoutBuffers.test.ts test/transcript-switch-back.test.tsx 2>&1 | grep -E "\(fail\)| pass$| fail$")
(cd webviews && bun run typecheck 2>&1 | tail -2)
python3 scripts/ci/react_doctor_gate.py --project webviews 2>&1 | grep -vE "^##\[error\]" | tail -4
(cd webviews && npx --no-install oxlint src/agent-session/acpmux/conversation/revealedMarkdownModel.ts src/agent-session/acpmux/conversation/revealClock.test.ts 2>&1 | tail -3)
