"""One unpaged `_acpmux/sessions` read: count and bytes of the list."""
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
f = s.makefile("rb")
s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientInfo":{"name":"hb-probe","version":"1"},"clientCapabilities":{}}}\n')
s.sendall(b'{"jsonrpc":"2.0","id":2,"method":"_acpmux/sessions","params":{}}\n')
while True:
    line = f.readline()
    if not line:
        print("probe: closed"); break
    m = json.loads(line)
    if m.get("id") == 2:
        r = m.get("result") or {}
        print(f"probe: sessions={len(r.get('sessions', []))} bytes={len(line)} error={m.get('error')}")
        break
