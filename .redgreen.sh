#!/bin/bash
# Scratch for the fleet job only (not committed): the new geometry test with the fix reverted (red),
# then applied (green), then the suites that read the same rows.
set -uo pipefail
root=$(pwd)
cd "$root"
git apply -R .fix.patch && echo "=== RED (fix reverted)"
(cd webviews && CMUX_BROWSER_TESTS=1 bun test test/transcript-spacing-reference.test.ts 2>&1 | grep -E 'TRANSCRIPT_SPACING|\(pass\)|\(fail\)|pass$|fail$|Expected|Received|^\s+"' | head -40)
git apply .fix.patch && echo "=== GREEN (fix applied)"
cd webviews
CMUX_BROWSER_TESTS=1 bun test test/transcript-spacing-reference.test.ts test/transcript-row-alignment.test.ts test/agent-pane-transcript-spacing.test.ts test/agent-pane-reply-actions.test.tsx test/agent-pane-reply-actions-frame.test.tsx test/transcript-hover-fade.test.ts test/transcript-send-remount.test.tsx test/pane-has-restyle.browser.test.ts src/agent-session/acpmux/rowEstimates.test.ts src/agent-session/acpmux/conversation/foldAnchor.test.ts src/agent-session/acpmux/conversation/footerActions.test.tsx src/agent-session/acpmux/continuationSpacing.test.ts src/agent-session/acpmux/plainUserHeight.test.ts test/transcript-continuation-spacing.test.ts 2>&1 | grep -E '\(fail\)|^ *[0-9]+ (pass|fail)|error:|Expected|Received|^\s+[-+] ' | head -120
