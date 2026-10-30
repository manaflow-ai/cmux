#!/bin/bash
# Lane scratch (not committed): red run against base pastedChips.ts, then before/after gallery captures.
set -uo pipefail
cd webviews
F=src/agent-session/acpmux/composer/pastedChips.ts
cp "$F" /tmp/pastedChips.fix.ts
echo "=== GREEN new test"; bun test test/composer-paste-again.test.tsx 2>&1 | grep -E '^\((pass|fail)\)| pass$| fail$| error|Ran '
echo "=== RED new test (base pastedChips.ts)"; cp ../.lane-scratch/pastedChips.base.ts.txt "$F"
bun test test/composer-paste-again.test.tsx 2>&1 | grep -E '^\((pass|fail)\)|Expected|Received|^\s+[-+] |toEqual|toBe\(| pass$| fail$| error|Ran ' | head -60
cat > /tmp/manifest.json <<'JSON'
[
 {"id":"paste-again-dark","path_or_url":"frame.html","params":{"entry":"agent-pane.composer","variant":"text-pasted-again","locale":"en","theme":"Apple System Colors","colorScheme":"dark","width":760,"height":420}},
 {"id":"paste-again-light","path_or_url":"frame.html","params":{"entry":"agent-pane.composer","variant":"text-pasted-again","locale":"en","theme":"Apple System Colors Light","colorScheme":"light","width":760,"height":420}}
]
JSON
G=src/agent-session/acpmux/composer.gallery.ts
cp "$G" /tmp/gallery.fix.ts
# Before: base pastedChips.ts, and the play's no-second-chip check off so the base state renders.
sed -i 's/if (ctx.document.querySelector(".acpmux-attachment-pasted"))$/if (false)/' "$G"
shoot() {
  local tag=$1
  rm -rf dist/gallery
  bun run gallery:build > /tmp/build-$tag.log 2>&1 || { tail -40 /tmp/build-$tag.log; return 1; }
  (cd ../scripts/gallery-matrix && CMUX_BROWSER_TESTS=1 CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest /tmp/manifest.json --gallery-dir ../../webviews/dist/gallery --output-dir /tmp/out-$tag --engines chromium 2>&1 | tail -15)
  python3 - "$tag" <<'PY'
import base64, io, json, sys, glob
from PIL import Image
tag = sys.argv[1]
for r in json.load(open(f"/tmp/out-{tag}/results.json")):
    print("RESULT", tag, r.get("id"), r.get("engine"), r.get("status"), json.dumps(r.get("play") or r.get("error") or "")[:400])
for p in sorted(glob.glob(f"/tmp/out-{tag}/*-chromium.png")):
    im = Image.open(p).convert("RGB")
    buf = io.BytesIO(); im.save(buf, "WEBP", lossless=True, method=6)
    data = base64.b64encode(buf.getvalue()).decode()
    name = p.rsplit("/", 1)[1].replace("-chromium.png", "")
    print(f"IMG-BEGIN {tag}-{name} {im.size[0]}x{im.size[1]} {len(buf.getvalue())}")
    for i in range(0, len(data), 2000): print("IMG-LINE " + data[i:i+2000])
    print(f"IMG-END {tag}-{name}")
PY
}
echo "=== BEFORE capture"; shoot before
cp /tmp/pastedChips.fix.ts "$F"; cp /tmp/gallery.fix.ts "$G"
echo "=== AFTER capture"; shoot after
git status --short
