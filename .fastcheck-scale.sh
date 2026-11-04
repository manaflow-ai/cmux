cd webviews || exit 1
bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1
rc=0
run() {
  name="$1"; shift
  echo "=== $name: $*"
  "$@" > /tmp/out.$$ 2>&1; c=$?
  cat /tmp/out.$$
  if [ $c -ne 0 ]; then
    rc=1
    msg=$(grep -E "fail|error|Error|✗|outside|\(fail\)|expect" /tmp/out.$$ | head -25 | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')
    echo "::error title=$name exit $c::$msg"
  else
    echo "::notice title=$name::ok"
  fi
}
run fmt npx --no-install vp fmt --check src/agent-session/acpmux/header test/chat-header-overflow.test.tsx test/chat-header-strip.test.tsx test/native-row-tools.test.tsx
run design-tokens bun run check:design-tokens
run icon-scale bun run check:icon-scale
run header-tests bun test test/chat-header-overflow.test.tsx test/chat-header-strip.test.tsx test/native-row-tools.test.tsx test/chat-header-more-spacing.test.ts test/chat-header-tab-row-surface.test.ts
run typecheck bun run typecheck
exit $rc
