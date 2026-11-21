#!/bin/bash
# One fleet round: probe the sources, build, verify, draw specimens; results come back as base64 lines.
cd "$(dirname "$0")"
D=/tmp/quillet-sans-deps
[ -d $D/fontTools ] || python3 src/deps.py $D || exit 1
export PYTHONPATH=$D
python3 -c 'import fontTools.varLib.hvar as h; print("HAS_HVAR_MODULE", hasattr(h, "add_HVAR"))' || echo "HAS_HVAR_MODULE False"
[ "$1" = probe ] && python3 src/probe.py | gzip -9c | base64 -w0 | sed 's/^/QS_PROBE /'; echo
mkdir -p fonts-out
python3 src/sans.py --out fonts-out; echo "BUILD_EXIT $?"
python3 src/verify.py fonts-out | tee /tmp/qs-verify.txt | cut -c1-3000; echo "VERIFY_EXIT ${PIPESTATUS[0]}"
python3 src/specimen.py /tmp/qs-spec.svg "Hanken=sources/HankenGrotesk[wght].ttf" "Quillet=fonts-out/quillet-sans.woff2" "QuilletItalic=fonts-out/quillet-sans-italic.woff2" && echo "QS_SPEC $(gzip -9c /tmp/qs-spec.svg | base64 -w0)"
for f in fonts-out/quillet-sans.woff2 fonts-out/quillet-sans-italic.woff2 build/out/sans.json; do [ -f "$f" ] && echo "QS_FILE $(basename $f) $(gzip -9c $f | base64 -w0)"; done
exit 0
