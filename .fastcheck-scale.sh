cd webviews || exit 1
bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1
rc=0
run() { echo "=== $*"; "$@"; c=$?; echo "=== exit $c: $*"; [ $c -ne 0 ] && rc=1; }
run npx --no-install vp fmt --check src/agent-session/acpmux/header test/chat-header-overflow.test.tsx test/chat-header-strip.test.tsx test/native-row-tools.test.tsx
run bun run check:design-tokens
run bun run check:icon-scale
run bun test test/chat-header-overflow.test.tsx test/chat-header-strip.test.tsx test/native-row-tools.test.tsx test/chat-header-more-spacing.test.ts test/chat-header-tab-row-surface.test.ts
run bun run typecheck
exit $rc
