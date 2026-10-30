set -u
root=$(git rev-parse --show-toplevel); cd "$root/cmux-tui"
read -r -a f <<<"$(python3 ../scripts/cmux-next/rust_panic_ratchet.py --flags)"
measure() {
  cargo clippy --workspace --lib --bins --locked --message-format=json -- "${f[@]}" > /tmp/h-$1.jsonl 2>/tmp/h.err; echo "$1 WS_CLIPPY_RC=$?"
  grep -E '^error' -A6 /tmp/h.err | head -12
  python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/h-$1.jsonl > /tmp/r-$1.log 2>&1; r=$?
  grep -E "RED|crates checked|did not finish" /tmp/r-$1.log | head -6
  python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/h-$1.jsonl --report json 2>/dev/null | python3 -c 'import json,sys; c=json.load(sys.stdin)["acpmux"]["counts"]; print("COUNTS_'"$1"'", json.dumps({k:c.get(k,0) for k in ("indexing_slicing","string_slice","unwrap_used","expect_used")}))'
  echo "$1 RATCHET_RC=$r"
  python3 - "$1" <<'PY'
import json,sys,collections
tag=sys.argv[1]; per=collections.Counter()
for l in open(f"/tmp/h-{tag}.jsonl"):
    try: m=json.loads(l)
    except Exception: continue
    if m.get("reason")!="compiler-message" or m.get("target",{}).get("name")!="acpmux": continue
    code=(m["message"].get("code") or {}).get("code","")
    if code not in ("clippy::indexing_slicing","clippy::string_slice","clippy::unwrap_used","clippy::expect_used"): continue
    s=next((s for s in m["message"]["spans"] if s.get("is_primary")),None)
    if s: per[(code.split("::")[1], s["file_name"])]+=1
json.dump({f"{k[0]} {k[1]}":v for k,v in per.items()}, open(f"/tmp/per-{tag}.json","w"))
PY
}
measure TIP
git -C "$root" apply "$root"/.measure/to-b7196082.patch; echo "APPLY_B=$?"
measure B7196082
git -C "$root" apply -R "$root"/.measure/to-b7196082.patch; echo "UNAPPLY_B=$?"
git -C "$root" apply "$root"/.measure/to-abe139dc.patch; echo "APPLY_GOOD=$?"
measure ABE139DC
python3 - <<'PY'
import json
t=json.load(open("/tmp/per-TIP.json")); g=json.load(open("/tmp/per-ABE139DC.json")); b=json.load(open("/tmp/per-B7196082.json"))
for k in sorted(set(t)|set(g)|set(b)):
    if t.get(k,0)!=g.get(k,0) or b.get(k,0)!=g.get(k,0):
        print(f"PERFILE {k}: abe139dc={g.get(k,0)} b7196082={b.get(k,0)} tip={t.get(k,0)}")
PY
