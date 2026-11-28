cd webviews
(bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1)
for f in "$@"; do timeout 300 bun test "$f" 2>&1 | grep -E "DBG|fail|error" | head -80; done
exit 0
