import json,sys
for l in open(sys.argv[1]):
    try: m=json.loads(l)
    except Exception: continue
    if m.get("reason")!="compiler-message": continue
    msg=m["message"]; c=(msg.get("code") or {}).get("code","")
    if c not in("clippy::indexing_slicing","clippy::string_slice","clippy::unwrap_used","clippy::expect_used","clippy::panic","clippy::unreachable"): continue
    for s in msg["spans"]:
        if s["is_primary"]:
            t=s["text"][0]["text"].strip() if s["text"] else ""
            print(f'HIT\t{c}\t{s["file_name"]}\t{s["line_start"]}\t{t}')
