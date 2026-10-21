import socket, json, base64, time, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(3)
buf = b""
def send(o):
    s.sendall((json.dumps(o) + "\n").encode())
def read(t=1.5):
    global buf
    out = []; end = time.time() + t
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d: break
            buf += d
        except socket.timeout: break
        while b"\n" in buf:
            l, buf = buf.split(b"\n", 1); out.append(json.loads(l))
    return out
def show(objs):
    for o in objs:
        o2 = dict(o)
        for k in ("data", "replay", "pending"):
            if isinstance(o2.get(k), str):
                o2[k] = "b64(" + repr(base64.b64decode(o2[k])[:60]) + ")"
        print(json.dumps(o2)[:300])
send({"id": "1", "cmd": "identify"}); show(read())
send({"id": "2", "cmd": "new-workspace"}); r = read(); show(r)
r = []
surf = 2
for o in r:
    d = o.get("data")
    if isinstance(d, dict):
        for x in d.get("surfaces", []):
            surf = x.get("id", x.get("surface"))
    elif isinstance(d, list) and d:
        surf = d[0].get("id", d[0].get("surface"))
print("surface", surf)
send({"id": "4", "cmd": "attach-surface", "surface": surf}); show(read(2))
send({"id": "5", "cmd": "send", "surface": surf, "bytes": base64.b64encode(b"echo hi-from-probe\r").decode()}); show(read(2))
send({"id": "6", "cmd": "resize-surface", "surface": surf, "cols": 54, "rows": 42}); show(read(2))
send({"id": "7", "cmd": "send", "surface": surf, "text": "printf '\\033[?1049h'; sleep 1; printf '\\033[?1049l'\r"}); show(read(3))
