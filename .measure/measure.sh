set -u
root=$(git rev-parse --show-toplevel)
measure() {
  read -r -a f <<<"$(python3 ../scripts/cmux-next/rust_panic_ratchet.py --flags)"
  cargo clippy --workspace --lib --bins --locked --message-format=json -- "${f[@]}" > /tmp/h-$1.jsonl 2>/dev/null; echo "$1 WS_CLIPPY_RC=$?"
  python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/h-$1.jsonl > /tmp/r-$1.log 2>&1; echo "$1 RATCHET_RC=$?"
  grep -v -E '^\s*$' /tmp/r-$1.log | grep -E 'RED|>|did not|::error' | sed "s/^/$1 R: /" | head -20
  python3 - "$1" <<'PY'
import json,sys,collections
tag=sys.argv[1]; per=collections.Counter()
for l in open(f"/tmp/h-{tag}.jsonl"):
    try: m=json.loads(l)
    except Exception: continue
    if m.get("reason")!="compiler-message": continue
    code=(m["message"].get("code") or {}).get("code","")
    if not code.startswith("clippy::") or code in ("clippy::arithmetic_side_effects","clippy::cast_possible_truncation"): continue
    s=next((s for s in m["message"]["spans"] if s.get("is_primary")),None)
    if s: per[f'{m.get("target",{}).get("name")} {code.split("::")[1]} {s["file_name"]}']+=1
json.dump(per, open(f"/tmp/per-{tag}.json","w"))
PY
}
cd "$root/cmux-tui"; measure TIP
git -C "$root" fetch -q --depth=1 origin 976656f26b15eb65444d5ff0643ae27e22648545; echo "FETCH_GOOD=$?"
git -C "$root" worktree add -q --detach /tmp/good FETCH_HEAD
rm -rf /tmp/good/ghostty-next; ln -sfn "$root/ghostty-next" /tmp/good/ghostty-next
cd /tmp/good/cmux-tui; measure GOOD
python3 - <<'PY'
import json
t=json.load(open("/tmp/per-TIP.json")); g=json.load(open("/tmp/per-GOOD.json"))
for k in sorted(set(t)|set(g)):
    if t.get(k,0)>g.get(k,0): print(f"UP {k}: good976656f2={g.get(k,0)} tip={t.get(k,0)}")
PY
