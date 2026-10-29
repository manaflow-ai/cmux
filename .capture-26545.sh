#!/bin/bash
# Builds the gallery, renders agent-pane.composer variants in Chromium (light + dark), prints PNGs as base64.
set -euo pipefail
root=$(pwd)
cd "$root/webviews"
bun run gallery:build >/tmp/gallery-build.log 2>&1 || { tail -50 /tmp/gallery-build.log; exit 1; }
bun scripts/gallery/manifest.ts --entries agent-pane.composer --variants "$1" --themes pair --frame component --widths normal --out /tmp/m.json
cd "$root/scripts/gallery-matrix"
bun install >/dev/null 2>&1
bunx playwright install --with-deps chromium >/dev/null 2>&1
CMUX_BROWSER_TESTS=1 CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest /tmp/m.json --gallery-dir "$root/webviews/dist/gallery" --output-dir /tmp/out --engines chromium --threshold 100 || true
find /tmp/out -name '*.png' | sort
cat /tmp/out/results.json 2>/dev/null | head -c 3000; echo
for f in $(find /tmp/out -name '*.png' -not -name '*step*' | sort); do
  echo "=====PNG $(basename "$f")"
  base64 -w0 "$f"; echo
  echo "=====END"
done
