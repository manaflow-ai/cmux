#!/usr/bin/env bash
# Fleet wrapper for Quillet Serif: get fontTools + brotli, run one script, print files as gzip+base64 lines.
#   run.sh inspect | run.sh build
set -u
cd "$(dirname "$0")"
export PATH=$HOME/.local/bin:$HOME/.cargo/bin:$PATH
PY=""
if command -v uv >/dev/null 2>&1; then
  PY="uv run --no-project --with fonttools[woff]==4.60.1 --with brotli==1.1.0 python3"
elif python3 -m venv /tmp/qserif-venv >/dev/null 2>&1 && /tmp/qserif-venv/bin/pip -q install "fonttools[woff]==4.60.1" brotli==1.1.0; then
  PY=/tmp/qserif-venv/bin/python
else
  # No uv, no ensurepip: unpack the PyPI wheels (pinned versions, files.pythonhosted.org) onto PYTHONPATH.
  SITE=/tmp/qserif-site; mkdir -p "$SITE"
  python3 - "$SITE" <<'EOF'
import io, json, sys, sysconfig, urllib.request, zipfile
site = sys.argv[1]
tag = f"cp{sys.version_info.major}{sys.version_info.minor}"
arch = sysconfig.get_platform().split("-")[-1]
for pkg, ver in (("fonttools", "4.60.1"), ("brotli", "1.1.0")):
    files = json.load(urllib.request.urlopen(f"https://pypi.org/pypi/{pkg}/{ver}/json"))["urls"]
    wheels = [f for f in files if f["filename"].endswith(".whl")]
    pick = ([f for f in wheels if tag in f["filename"] and "manylinux" in f["filename"] and arch in f["filename"]]
            or [f for f in wheels if "py3-none-any" in f["filename"]])
    w = pick[0]
    data = urllib.request.urlopen(w["url"]).read()
    import hashlib
    assert hashlib.sha256(data).hexdigest() == w["digests"]["sha256"], w["filename"]
    zipfile.ZipFile(io.BytesIO(data)).extractall(site)
    print("wheel", w["filename"])
EOF
  export PYTHONPATH=$SITE
  PY=python3
fi
$PY -c "import fontTools, brotli; print('fontTools', fontTools.version)"
case "${1:-build}" in
  inspect) $PY src/inspect_serif.py; rc=$? ;;
  build)
    $PY src/serif.py --out out-fonts; rc=$?
    [ "$rc" = 0 ] && $PY src/specimen.py out-fonts
    for f in out-fonts/quillet-serif.woff2 out-fonts/quillet-serif-italic.woff2 build/out/serif.json out-fonts/specimen.svg; do
      [ -f "$f" ] && echo "QSERIF-FILE $(basename "$f") $(gzip -9c "$f" | base64 -w0)"
    done
    if [ -n "${FAST_CHECKS_OUT:-}" ]; then cp out-fonts/*.woff2 build/out/serif.json "$FAST_CHECKS_OUT"/ 2>/dev/null; fi
    ;;
esac
echo "QSERIF-RC $rc"
exit $rc
