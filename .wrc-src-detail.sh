set -o pipefail
cd webviews
(bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1)
for f in "$@"; do
  if timeout 300 bun test "$f" > /tmp/out.txt 2>&1; then echo "PASS $f"; else echo "FAIL $f"; grep -vE "^\s*$|^\(pass\)" /tmp/out.txt | grep -B2 -A40 -E "^error:|^\(fail\)" | head -150; fi
done
exit 0
