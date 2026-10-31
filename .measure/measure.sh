set -u
root=$(git rev-parse --show-toplevel); cd "$root/cmux-tui"
read -r -a f <<<"$(python3 ../scripts/cmux-next/rust_panic_ratchet.py --flags)"
cargo clippy --workspace --lib --bins --locked --message-format=json -- "${f[@]}" > /tmp/h.jsonl 2>/dev/null; echo "WS_CLIPPY_RC=$?"
python3 ../scripts/cmux-next/rust_panic_ratchet.py --clippy-json /tmp/h.jsonl > /tmp/r.log 2>&1; echo "RATCHET_RC=$?"
grep -E 'RED|::error|did not|>' /tmp/r.log | sed 's/^/R: /' | head -40
python3 - <<'PY'
import json
seen=set()
for ln in open('/tmp/h.jsonl'):
    try: m=json.loads(ln)
    except Exception: continue
    if m.get('reason')!='compiler-message': continue
    msg=m['message']; c=(msg.get('code') or {}).get('code') or ''
    if c not in ('clippy::indexing_slicing','clippy::string_slice','clippy::unwrap_used','clippy::expect_used'): continue
    sp=[s for s in msg['spans'] if s.get('is_primary')]
    if not sp: continue
    k=(c[8:],sp[0]['file_name'],sp[0]['line_start'],sp[0]['column_start'])
    if k in seen: continue
    seen.add(k); print('L',*k)
PY
