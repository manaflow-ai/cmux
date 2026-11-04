cd webviews
npx --no-install vp fmt --check 2>&1 | tail -15 || true
bun run check:fix >/dev/null 2>&1
echo "=====PATCH-BEGIN"
git diff
echo "=====PATCH-END"
