import json, os, subprocess, sys, time
os.environ["DEVELOPER_DIR"] = "/Applications/Xcode.app/Contents/Developer"
U = open("/tmp/imsg-parity/udid").read().strip()
def axe(*a, check=True):
    r = subprocess.run(["axe", *a, "--udid", U], capture_output=True, text=True)
    if check and r.returncode: raise RuntimeError(r.stderr + r.stdout)
    return r.stdout
def ui():
    d = json.loads(axe("describe-ui"))
    out = []
    def w(n):
        out.append(n)
        for c in n.get("children", []) or []: w(c)
    for n in (d if isinstance(d, list) else [d]): w(n)
    return out
def find(label=None, contains=None, typ=None):
    res = []
    for n in ui():
        l = n.get("AXLabel") or ""
        if label is not None and l != label: continue
        if contains is not None and contains not in l: continue
        if typ and n.get("type") != typ: continue
        res.append(n)
    return res
def center(n):
    f = n["frame"]; return f["x"] + f["width"]/2, f["y"] + f["height"]/2
def tap(x, y): axe("tap", "-x", str(x), "-y", str(y))
def tapn(n): tap(*center(n))
def long_press(x, y, d=0.8): axe("touch", "-x", str(x), "-y", str(y), "--down", "--up", "--delay", str(d))
def typ(t): axe("type", t)
def ret(): axe("key", "40")
def shot(path): axe("screenshot", "--output", path)
def wait(s): time.sleep(s)
def dump(filt=None):
    for n in ui():
        l = n.get("AXLabel"); f = n.get("frame", {})
        if filt and (not l or filt not in l): continue
        if l: print(n.get("type"), repr(l)[:80], {k: round(v, 1) for k, v in f.items()})
if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "dump": dump(sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd == "shot": shot(sys.argv[2])
JA = "+1 (888) 555-1212"; KB = "+1 (555) 564-8583"
def back_to_list():
    for _ in range(3):
        b = find(label="Back", typ="Button")
        if not b: break
        tapn(b[0]); wait(0.8)
def open_chat(phone):
    for attempt in range(12):
        back_to_list()
        hdr = [n for n in find(contains=phone) if n["frame"]["y"] < 200]
        rows = [n for n in find(contains=phone) if n.get("type") in ("Group", "Cell", "Button") and n["frame"]["height"] > 50]
        if not rows: rows = [n for n in find(label=phone) if n.get("type") == "StaticText" and n["frame"]["y"] > 150]
        if rows: tapn(rows[0]); wait(1.2); return
        wait(1.0)
    raise RuntimeError("no chat row " + phone)
def bubble(text):
    c = [n for n in find(contains=text) if n.get("type") == "GenericElement"]
    if not c: raise RuntimeError("no bubble " + text)
    return c[-1]
def send(text):
    tf = find(typ="TextField")
    tapn(tf[0]); wait(0.3); typ(text); wait(0.2); ret(); wait(1.0)
def reply(to, text):
    long_press(*center(bubble(to))); wait(1.2)
    r = find(label="Reply")
    if not r: raise RuntimeError("no Reply menu: " + str([n.get('AXLabel') for n in ui() if n.get('type')=='Button'][:30]))
    tapn(r[0]); wait(1.0); typ(text); wait(0.2); ret(); wait(1.2)
def relaunch():
    U_ = U
    subprocess.run(["xcrun", "simctl", "terminate", U_, "com.apple.MobileSMS"], capture_output=True)
    env = dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="/tmp/imsg-parity/hook/hook.dylib:" + os.environ.get("REPLYON", "/tmp/imsg-parity/hook/ReplyOn.dylib"))
    subprocess.run(["xcrun", "simctl", "launch", U_, "com.apple.MobileSMS"], env=env, capture_output=True)
    wait(2.5)
def hook_reply(target, text):
    open("/tmp/imsg-parity/hook/target.txt", "w").write(target)
    subprocess.run(["xcrun", "simctl", "spawn", U, "notifyutil", "-p", "com.cmux.imsghook.reply"], capture_output=True)
    wait(1.5)
    if text is not None:
        typ(text); wait(0.2); ret(); wait(1.5)
def hooklog(n=20):
    r = subprocess.run(["xcrun", "simctl", "spawn", U, "log", "show", "--last", "3m", "--predicate", 'eventMessage CONTAINS "imsghook"'], capture_output=True, text=True)
    print("\n".join(r.stdout.splitlines()[-n:]))
