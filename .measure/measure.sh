set -u
root=$(git rev-parse --show-toplevel); cd "$root/cmux-tui"
read -r -a f <<<"$(python3 ../scripts/cmux-next/rust_panic_ratchet.py --flags)"
measure() {
  cargo clippy --workspace --lib --bins --locked --message-format=json -- "${f[@]}" > /tmp/h-$1.jsonl 2>/tmp/h.err; echo "$1 WS_CLIPPY_RC=$?"
  grep -E '^error' -A6 /tmp/h.err | head -12
  python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/h-$1.jsonl > /tmp/r.log 2>&1; r=$?
  grep -E "RED|crates checked|did not finish" /tmp/r.log | head -6
  python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/h-$1.jsonl --report json 2>/dev/null | python3 -c 'import json,sys; c=json.load(sys.stdin)["acpmux"]["counts"]; print("COUNTS_'"$1"'", json.dumps({k:c.get(k,0) for k in ("indexing_slicing","string_slice","unwrap_used","expect_used")})); sys.exit(0 if c.get("indexing_slicing",0)<=686 and c.get("string_slice",0)<=94 and c.get("unwrap_used",0)<=143 and c.get("expect_used",0)<=18 else 1)'; g=$?
  echo "$1 RATCHET_RC=$r GATE=$g"
  # the acpmux hits of the 4 deny-ratcheted lints, for naming lines when over
  python3 - "$1" <<'PY'
import json,sys
tag=sys.argv[1]; out=[]
for l in open(f"/tmp/h-{tag}.jsonl"):
    try: m=json.loads(l)
    except Exception: continue
    if m.get("reason")!="compiler-message" or m.get("target",{}).get("name")!="acpmux": continue
    code=(m["message"].get("code") or {}).get("code","")
    if code not in ("clippy::indexing_slicing","clippy::string_slice","clippy::unwrap_used","clippy::expect_used"): continue
    s=next((s for s in m["message"]["spans"] if s.get("is_primary")),None)
    if s: out.append(f"{code.split('::')[1]} {s['file_name']}:{s['line_start']}")
open(f"/tmp/hits-{tag}.txt","w").write("\n".join(sorted(set(out))))
PY
}
measure TIP
git -C "$root" apply "$root"/.measure/merge-28428.patch; echo "APPLY_28428=$?"
measure M28428
echo "== NEW hits in M28428 vs TIP (line numbers shift in changed files)"; comm -13 /tmp/hits-TIP.txt /tmp/hits-M28428.txt | head -30
