set -euo pipefail
ROOT=$PWD
A=src/agent-session/acpmux
E=agent-pane.waiting-messages-card
cd "$ROOT/webviews"
echo ===CHECKS
F="src/agent-session/acpmux/App.tsx src/agent-session/acpmux/direct.ts src/agent-session/acpmux/model.ts src/agent-session/acpmux/conversation/WaitingMessagesCard.css src/agent-session/acpmux/conversation/WaitingMessagesCard.gallery.ts src/agent-session/acpmux/conversation/WaitingMessagesCard.tsx src/agent-session/acpmux/conversation/waitingMessages.ts test/waiting-messages-card.test.tsx"
./node_modules/.bin/vp fmt --check $F 2>&1 | tail -4
bun run typecheck 2>&1 | tail -6
bun run lint 2>&1 | tail -4
bun run check:catalog-keys 2>&1 | tail -4
bun test test/waiting-messages-card.test.tsx test/queue-agent-message.test.tsx test/agent-pane-pending-steer.test.tsx test/agent-pane-queue.test.ts test/agent-pane-steer-take-back.test.tsx test/transcript-steer-continuous.test.tsx test/steer-no-caption.test.tsx test/queue-row-actions.test.tsx 2>&1 | grep -E "^\(fail\)|^ *[0-9]+ (pass|fail)|^Ran|waiting-messages|error:" | head -30
echo ===ENDCHECKS
bun scripts/gallery/manifest.ts --entries $E --variants step,step-open,turn,turn-three,turn-open,minimal,count-only,chips,single --themes pair --widths narrow,normal --frame component --out /tmp/head.json
CMUX_GALLERY_OUT_DIR=/tmp/gallery-head bun run gallery:build > /tmp/head-build.log 2>&1 || { tail -40 /tmp/head-build.log; exit 1; }
for f in App.tsx direct.ts model.ts Localizable.xcstrings; do cp "$ROOT/.capture-base/$f" $A/$f; done
rm $A/conversation/WaitingMessagesCard.tsx $A/conversation/WaitingMessagesCard.css $A/conversation/waitingMessages.ts
bun scripts/gallery/manifest.ts --entries $E --variants step,turn,turn-three --themes pair --widths narrow,normal --frame component --out /tmp/base.json
CMUX_GALLERY_OUT_DIR=/tmp/gallery-base bun run gallery:build > /tmp/base-build.log 2>&1 || { tail -40 /tmp/base-build.log; exit 1; }
cd "$ROOT/scripts/gallery-matrix"
bun install --frozen-lockfile >/dev/null
./node_modules/.bin/playwright install --with-deps --only-shell chromium >/dev/null 2>&1
for stage in head base; do
  CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest /tmp/$stage.json --gallery-dir /tmp/gallery-$stage --output-dir /tmp/out-$stage --engines chromium --shard-count 1 --shard-index 0 > /tmp/run-$stage.log 2>&1 || { echo "runner $stage exited $?"; tail -30 /tmp/run-$stage.log; }
done
for stage in head base; do
  for png in /tmp/out-$stage/*.png; do
    case "$png" in *-diff.png) continue;; esac
    echo "=====PNG $stage $(basename "$png")"
    base64 -w 120 "$png"
    echo "=====END"
  done
done
