set -u
root=$(git rev-parse --show-toplevel); cd "$root/cmux-tui"
read -r -a f <<<"$(python3 ../scripts/cmux-next/rust_panic_ratchet.py --flags)"
cargo clippy --workspace --lib --bins --locked --message-format=json -- "${f[@]}" > /tmp/h.jsonl 2>/dev/null; echo "WS_CLIPPY_RC=$?"
python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/h.jsonl > /tmp/r.log 2>&1; echo "RATCHET_RC=$?"
grep -E 'RED|::error|did not' /tmp/r.log | sed 's/^/R: /' | head -20
python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/h.jsonl --report json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); [print("COUNTS", k, json.dumps({l:d[k]["counts"].get(l,0) for l in ("indexing_slicing","string_slice","unwrap_used","expect_used")})) for k in ("cmux-tui-core","acpmux","cmux-tui")]'
