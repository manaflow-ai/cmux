set -o pipefail
cd webviews
(bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1)
UPDATE_ICON_MARKUP=1 timeout 300 bun test src/agent-session/acpmux/icons/iconDefaultMarkup.test.tsx > /tmp/icons.txt 2>&1; echo "regen rc=$?"; tail -5 /tmp/icons.txt
echo "=====SNAPSHOT-BEGIN====="
cat src/agent-session/acpmux/icons/iconDefaultMarkup.snapshot.json
echo "=====SNAPSHOT-END====="
cd ..
bash .wrc-src-detail.sh "$@"
