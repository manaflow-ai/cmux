set -u
ROOT=$(pwd)
BASE=218e3cbcb8197094e800319c02e0444677609b38
cap() { # dir outdir variants
  ( cd "$1/webviews" && bun run gallery:build >/tmp/gb-$2.log 2>&1 || { tail -30 /tmp/gb-$2.log; exit 1; }
    bun scripts/gallery/manifest.ts --entries agent-pane.chat-inspector --variants "$3" --themes pair --frame component --widths normal --out /tmp/m-$2.json && cat /tmp/m-$2.json | head -c 600; echo
    cd "$ROOT/scripts/gallery-matrix" && CMUX_BROWSER_TESTS=1 CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest /tmp/m-$2.json --gallery-dir "$1/webviews/dist/gallery" --output-dir /tmp/out-$2 --engines chromium 2>&1 | tail -8 )
}
(cd scripts/gallery-matrix && bun install >/dev/null 2>&1)
git worktree add -q /tmp/basewt $BASE 2>&1 | tail -2
ln -s "$ROOT/webviews/node_modules" /tmp/basewt/webviews/node_modules
cap /tmp/basewt before full
cap "$ROOT" after full,reorder-dragging
find /tmp/out-before /tmp/out-after -name '*.png' | head -20
tar -czf /tmp/shots.tgz -C /tmp out-before out-after --exclude='*.html'
echo "SHOTS:$(base64 -w0 /tmp/shots.tgz)"
