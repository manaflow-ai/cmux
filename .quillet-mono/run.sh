#!/usr/bin/env bash
# Fleet wrapper: fontTools + brotli, probe, build Quillet Mono, print outputs as gzip+base64 lines.
set -u
cd "$(dirname "$0")"
D=/tmp/quillet-mono-deps
if PYTHONPATH=$D python3 -c 'import fontTools, brotli' 2>/dev/null; then :; else python3 src/deps.py $D || exit 1; fi
export PYTHONPATH=$D
python3 -c 'import fontTools; print("fonttools", fontTools.version)'
python3 src/probe_mono.py
mkdir -p out-fonts
python3 src/mono.py --out out-fonts
rc=$?
for f in out-fonts/quillet-mono.woff2 out-fonts/quillet-mono-italic.woff2 build/out/mono.json; do
  [ -f "$f" ] && echo "QMONO-FILE $(basename $f) $(gzip -9c "$f" | base64 -w0)"
done
if [ -n "${FAST_CHECKS_OUT:-}" ]; then cp out-fonts/*.woff2 build/out/mono.json "$FAST_CHECKS_OUT"/ 2>/dev/null; fi
echo "QMONO-RC $rc"
exit $rc
