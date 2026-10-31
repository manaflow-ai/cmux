set -euo pipefail
root=$PWD; out=$root/.cap-out; mkdir -p $out
cd $root/scripts/gallery-matrix && bun install --frozen-lockfile >/dev/null 2>&1 && ./node_modules/.bin/playwright install --with-deps --only-shell chromium >/dev/null 2>&1
render() {
  cd $root/webviews
  bun scripts/gallery/manifest.ts --entries prototype.table-chart --variants split-large --themes pair --widths normal --frame component --out $out/m-$1.json
  CMUX_GALLERY_OUT_DIR=$out/g-$1 bun run gallery:build >/dev/null 2>&1
  cd $root/scripts/gallery-matrix
  CMUX_GALLERY_IN_VM=1 bun runner.ts --manifest $out/m-$1.json --gallery-dir $out/g-$1 --output-dir $out/$1 --engines chromium --shard-count 1 --shard-index 0 || echo "runner exit $?"
}
cd $root/webviews && bun install --frozen-lockfile >/dev/null 2>&1
render after
css=$root/webviews/src/prototypes/table-chart/table-chart.css
python3 - "$css" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
old=".tc-split > div:first-child .tc-table-wrap {\n  max-height: min(520px, 60vh);\n}\n"
assert old in s; open(p,"w").write(s.replace(old,""))
PY
grep -c 'min(520px' $css || true
render before
for f in $out/after/*.png $out/before/*.png; do case $f in *step*) continue;; esac; echo "=====BEGIN $(basename $(dirname $f))/$(basename $f)"; base64 -w0 $f; echo; echo "=====END"; done
