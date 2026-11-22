#!/usr/bin/env python3
"""hub.py TAG ACTION [JSON]: debug.device_hub on the tagged host; `me` prints this device; `approve` decides pending requests always_full."""
import json, socket, sys
tag, action = sys.argv[1], sys.argv[2]
def rpc(params):
    s = socket.socket(socket.AF_UNIX); s.settimeout(60); s.connect(f"/tmp/cmux-debug-{tag}.sock")
    s.sendall((json.dumps({"id": 1, "method": "debug.device_hub", "params": params}) + "\n").encode())
    b = b""
    while not b.endswith(b"\n"):
        c = s.recv(1 << 20)
        if not c: break
        b += c
    return json.loads(b)["result"]
if action == "me":
    st = rpc({"action": "state"})
    print(json.dumps({k: v for k, v in st.items() if k not in ("devices", "permissions")}))
    print(json.dumps([d for d in st["devices"] if d["this"]]))
elif action == "approve":
    st = rpc({"action": "state"})
    for r in st.get("pending_requests", []):
        sid = r.get("id") or r.get("session")
        print(sid, rpc({"action": "decide", "session": sid, "choice": sys.argv[3] if len(sys.argv) > 3 else "always_full"}))
else:
    params = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
    params["action"] = action
    print(json.dumps(rpc(params))[:3000])
