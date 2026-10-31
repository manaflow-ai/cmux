set -uo pipefail
OUT="${FAST_CHECKS_OUT:-$(mktemp -d)}"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
cd webviews
bun install --frozen-lockfile >/dev/null
echo "== gallery tests"
bun test test/gallery-coverage.test.ts test/gallery-env.test.ts test/pane-english.test.ts test/gallery-agent-pane-entries.test.ts test/gallery-entry-store.test.ts 2>&1 | grep -E "^\(fail\)|^\s+[0-9]+ (pass|fail)|error|Expected|Received|^[-+] " | head -60
echo "== check (lint, fmt, types) on the new file"
bun run check 2>&1 | grep -iE "AppWindow|error|✖|fail" | head -30
echo "== manifest"
bun scripts/gallery/manifest.ts --entries app.window --themes pair --out "$TMP/m.json"
jq length "$TMP/m.json"
CMUX_GALLERY_OUT_DIR="$TMP/gal" bun run gallery:build >/dev/null 2>&1 || echo build-failed
cd ../scripts/gallery-matrix && bun install --frozen-lockfile >/dev/null
./node_modules/.bin/playwright install --with-deps --only-shell chromium >/dev/null 2>&1
CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest "$TMP/m.json" --gallery-dir "$TMP/gal" --output-dir "$OUT/render" --engines chromium --shard-count 1 --shard-index 0 2>&1 | tail -30
echo "== results"
jq -c '.[] | {id, status, ready, error, play: (.play.ok // .play.error // null)}' "$OUT/render/results.json" 2>/dev/null | cut -c1-400
find "$OUT/render" -name '*.png' | head -20
if [ -z "${FAST_CHECKS_OUT:-}" ]; then
  mkdir -p "$TMP/small"
  for f in $(find "$OUT/render" -name '*.png'); do
    n=$(echo "$f" | sed "s#$OUT/render/##; s#/#__#g; s#\.png\$#.jpg#")
    if python3 -c "import PIL" 2>/dev/null; then
      python3 -c "import sys;from PIL import Image;i=Image.open(sys.argv[1]).convert('RGB');i.thumbnail((1400,1400));i.save(sys.argv[2],quality=70)" "$f" "$TMP/small/$n"
    elif command -v ffmpeg >/dev/null; then ffmpeg -loglevel error -i "$f" -vf scale=1400:-1 -q:v 5 "$TMP/small/$n"
    elif command -v convert >/dev/null; then convert "$f" -resize 1400x1400 -quality 70 "$TMP/small/$n"
    else cp "$f" "$TMP/small/${n%.jpg}.png"; fi
  done
  du -sh "$TMP/small"
  echo "BEGIN-APPWIN-TGZ"; tar -C "$TMP/small" -czf - . | base64 -w 0; echo; echo "END-APPWIN-TGZ"
fi
