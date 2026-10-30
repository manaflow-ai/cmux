set -uo pipefail
ROOT=$PWD
OUT=$RUNNER_TEMP/audit
mkdir -p "$OUT/shots"
ENTRIES="${AUDIT_ENTRIES:-agent-pane.transcript,agent-pane.composer,agent-pane.composer-plus-menu,agent-pane.composer-pickers,agent-pane.model-picker,agent-pane.options-menu,agent-pane.chat-display-menu,agent-pane.retry-model-menu,agent-pane.open-in-menu,agent-pane.new-tab-page,agent-pane.reply-actions,ui.menu,ui.context-menu,ui.select,ui.popover,pages.settings}"
THEMES="${AUDIT_THEMES:-pair}"
cd "$ROOT/webviews"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null 2>&1
bun scripts/gallery/manifest.ts --entries "$ENTRIES" --themes "$THEMES" --widths normal --frame component --out "$OUT/all.json"
python3 - "$OUT/all.json" "$ENTRIES" "$OUT/m.json" <<'PY'
import json, sys
cases = json.load(open(sys.argv[1]))
want = set(sys.argv[2].split(","))
order=sys.argv[2].split(",")
per={}
keep=[]
for e in order:
    cs=[c for c in cases if c["params"]["entry"]==e]
    keep+=[c for c in cs if ("template-classic" in c["id"] or "--idle" in c["id"])]
cap = 40
print("cases", len(cases), "kept", len(keep))
json.dump(keep[:cap], open(sys.argv[3], "w"))
for c in keep[:cap]:
    print("CASE", c["id"])
PY
CMUX_GALLERY_OUT_DIR="$OUT/gallery" bun run gallery:build >"$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log"; exit 1; }
cd "$ROOT/scripts/gallery-matrix"
[ -d node_modules ] || bun install --frozen-lockfile >/dev/null 2>&1
bun runner.ts --manifest "$OUT/m.json" --gallery-dir "$OUT/gallery" --output-dir "$OUT/shots" --engines chromium --shard-count 1 --shard-index 0 > "$OUT/run.log" 2>&1 || echo "runner exit $?"
tail -5 "$OUT/run.log"
cd "$OUT/shots"
ls *.png | wc -l
if ! command -v convert >/dev/null 2>&1; then sudo apt-get install -y -qq imagemagick >/dev/null 2>&1 || true; fi
mkdir -p "$OUT/jpg"
for f in *.png; do
  case "$f" in *-diff.png) continue;; esac
  if command -v convert >/dev/null 2>&1; then
    convert "$f" -quality 80 "$OUT/jpg/${f%.png}.jpg"
  else
    cp "$f" "$OUT/jpg/"
  fi
done
cd "$OUT/jpg"
tar czf "$OUT/shots.tgz" .
ls -la "$OUT/shots.tgz"
base64 -w 60000 "$OUT/shots.tgz" | sed 's/^/IMGB64 /'
echo IMGB64-END
