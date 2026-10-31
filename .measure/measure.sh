set -u
root=$(git rev-parse --show-toplevel); cd "$root/cmux-tui"
read -r -a f <<<"$(python3 ../scripts/cmux-next/rust_panic_ratchet.py --flags)"
LINTS='("indexing_slicing","string_slice","unwrap_used","expect_used")'
measure() {
  cargo clippy --workspace --lib --bins --locked --message-format=json -- "${f[@]}" > /tmp/h-$1.jsonl 2>/tmp/h.err; echo "$1 WS_CLIPPY_RC=$?"
  grep -E '^error' -A6 /tmp/h.err | head -10
  python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/h-$1.jsonl > /tmp/r-$1.log 2>&1; echo "$1 RATCHET_RC=$?"
  grep -E "RED|did not finish" /tmp/r-$1.log | grep -E "acpmux|cmux-tui|did not" | head -6
  python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/h-$1.jsonl --report json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("COUNTS_'"$1"'", k, json.dumps({l:d[k]["counts"].get(l,0) for l in '"$LINTS"'})) for k in ("acpmux","cmux-tui")]'
  python3 - "$1" <<'PY'
import json,sys,collections
tag=sys.argv[1]; per=collections.Counter()
for l in open(f"/tmp/h-{tag}.jsonl"):
    try: m=json.loads(l)
    except Exception: continue
    if m.get("reason")!="compiler-message": continue
    tgt=m.get("target",{}).get("name")
    if tgt not in ("acpmux","cmux_tui","cmux-tui"): continue
    code=(m["message"].get("code") or {}).get("code","")
    if code not in ("clippy::indexing_slicing","clippy::string_slice","clippy::unwrap_used","clippy::expect_used"): continue
    s=next((s for s in m["message"]["spans"] if s.get("is_primary")),None)
    if s: per[f'{code.split("::")[1]} {s["file_name"]}']+=1
json.dump(per, open(f"/tmp/per-{tag}.json","w"))
PY
}
measure TIP
git -C "$root" apply "$root"/.measure/merge-28626.patch; echo "APPLY_28626=$?"
measure M28626
git -C "$root" apply -R "$root"/.measure/merge-28626.patch; echo "UNAPPLY_28626=$?"
git -C "$root" apply -R "$root"/.measure/merge-28626.patch 2>/dev/null
git -C "$root" fetch -q --depth=1 origin 976656f26b15eb65444d5ff0643ae27e22648545 2>&1 | tail -2; echo "FETCH_GOOD=$?"
git -C "$root" worktree add -q --detach /tmp/good FETCH_HEAD 2>&1 | tail -2 || git -C "$root" archive FETCH_HEAD | (mkdir -p /tmp/good && tar -x -C /tmp/good)
echo "GOOD_TREE=$(ls /tmp/good/cmux-tui/Cargo.toml 2>&1)"
rm -rf /tmp/good/ghostty-next; ln -sfn "$root/ghostty-next" /tmp/good/ghostty-next; echo "GOOD_GHOSTTY=$(ls -d /tmp/good/ghostty-next/src 2>&1)"
cd /tmp/good/cmux-tui
measure GOOD
cd "$root/cmux-tui"
python3 - <<'PY'
import json
t=json.load(open("/tmp/per-TIP.json")); m=json.load(open("/tmp/per-M28626.json")); g=json.load(open("/tmp/per-GOOD.json"))
for k in sorted(set(t)|set(m)|set(g)):
    if t.get(k,0)!=g.get(k,0) or m.get(k,0)!=t.get(k,0):
        print(f"PERFILE {k}: good976656f2={g.get(k,0)} tip={t.get(k,0)} tip+28626={m.get(k,0)}")
PY
