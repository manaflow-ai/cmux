set -uo pipefail
cd webviews
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null 2>&1
bun test test/new-tab-classic-lines.test.ts 2>&1 | grep -E "\(pass\)|\(fail\)|new-tab-classic-lines\]|error" | head
echo "== lanes"; bun run check:browser-lanes 2>&1 | tail -5
echo "== fmt"; bunx vp fmt test/new-tab-classic-lines.test.ts >/dev/null 2>&1
git diff -- test/new-tab-classic-lines.test.ts | base64 -w0 | sed 's/^/FMTB64 /'; echo
echo "== lint"; bunx vp lint test/new-tab-classic-lines.test.ts 2>&1 | tail -3
echo "== waits"; bun run check:fixed-waits 2>&1 | tail -3
echo "== tsc"; bunx vp check --no-fmt --no-lint 2>&1 | grep -E "new-tab-classic|error TS|Found" | head -10
