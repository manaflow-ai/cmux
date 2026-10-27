"""Agent chat stress rig (verify/agentqa/README.md). Runs ON a cmux mini.

The hidden e2e rig Mac (mac.py: own bundle id, config, credentials; launched with
`open -g -j`, never activated) whose acpmux runs in its own home with the
credit-free stress agent (agentqa_agent.py) as its default harness, and the iOS
app in one headless simulator driven with AXe. The rig stays up between calls,
so each scenario step is a short call:

    python3 -c 'from aq import *; up(MAC_APP, IOS_APP)'          # once
    python3 -c 'from aq import *; shot("x"); ocr()'
    python3 -c 'from aq import *; perf_start("stream"); ...; perf_stop()'
    python3 -c 'from aq import *; down()'

State (udid, app paths) lives in ~/agentqa/state.json. Evidence goes to
~/agentqa/ev/<run>/ (shots/, videos, perf/*.json).
"""
import datetime
import json
import os
import signal
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
E2E = os.environ.get("AQ_E2E", os.path.expanduser("~/agentqa/src/cmux-next-ios/verify/e2e"))
sys.path.insert(0, E2E)
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode_26.6.app/Contents/Developer")

ROOT = os.path.expanduser("~/agentqa")
STATE = os.path.join(ROOT, "state.json")
ACPMUX_HOME = os.path.join(ROOT, "rig", "acpmux")
WORK = os.path.join(ROOT, "work")
AGENT = os.path.join(HERE, "agentqa_agent.py")
FAKE = os.path.join(ROOT, "fake_agent.py")
SIM_NAME = os.environ.get("AQ_SIM", "agentqa-phone")


def load():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def save(st):
    os.makedirs(ROOT, exist_ok=True)
    json.dump(st, open(STATE, "w"), indent=2)


def ev_dir():
    st = load()
    d = st.get("ev") or os.path.join(ROOT, "ev", datetime.datetime.now().strftime("%m%d-%H%M"))
    os.makedirs(os.path.join(d, "shots"), exist_ok=True)
    return d


def log(msg):
    line = f"{time.strftime('%H:%M:%S')} {msg}"
    print(line, flush=True)
    with open(os.path.join(ev_dir(), "run.log"), "a") as f:
        f.write(line + "\n")


def sh(*a, timeout=120, check=False):
    r = subprocess.run(list(a), capture_output=True, text=True, timeout=timeout)
    if check and r.returncode:
        raise RuntimeError(f"{a[0]}: {(r.stderr or r.stdout).strip()[:400]}")
    return r


def prepare_acpmux(harnesses=None, default="fake"):
    """The stress agent as acpmux's default harness, asking for every tool."""
    os.makedirs(ACPMUX_HOME, mode=0o700, exist_ok=True)
    os.makedirs(WORK, exist_ok=True)
    cfg = {"harnesses": {"fake": {"argv": ["/usr/bin/env", f"FAKE_AGENT={FAKE}", "python3", AGENT]}},
           "defaultHarness": default, "permissionPolicy": "ask", "webAskingModes": {"fake": ["normal", "strict"]}}
    if harnesses:
        cfg["harnesses"].update(harnesses)
    path = os.path.join(ACPMUX_HOME, "config.json")
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
    os.chmod(path, 0o600)
    return cfg


def _mac(st=None):
    from mac import Mac
    st = st or load()
    m = Mac(os.path.join(ROOT, "rig"), st["mac_src"])
    m.launch_env = {"ACPMUX_HOME": ACPMUX_HOME}
    m.pid = (m.main_pids() or [None])[0]
    return m


def _sim(st=None):
    from sim import Sim
    st = st or load()
    return Sim(st["udid"], os.path.join(ev_dir(), "shots"))


def ctx():
    import journey
    from journey import Journey
    st = load()
    journey.BUNDLE = st["bundle"]
    s, m = _sim(st), _mac(st)
    return s, m, Journey(s, m, ev_dir(), st["ios_app"], log)


def up(mac_app, ios_app, ios="26", fresh=True):
    """Prepares and launches the rig Mac, boots the phone, installs and signs in."""
    import journey
    from e2e import RUNTIMES, ensure_sim
    from journey import Journey
    from mac import Mac, pb, refuse_other_rigs
    st = load()
    st.update(mac_src=os.path.abspath(mac_app), ios_app=os.path.abspath(ios_app),
              bundle=pb(os.path.join(ios_app, "Info.plist"), "Print :CFBundleIdentifier"),
              ev=os.path.join(ROOT, "ev", datetime.datetime.now().strftime("%m%d-%H%M")))
    save(st)
    journey.BUNDLE = st["bundle"]
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    prepare_acpmux()
    m = Mac(os.path.join(ROOT, "rig"), mac_app)
    m.launch_env = {"ACPMUX_HOME": ACPMUX_HOME}
    m.prepare()
    m.seed_pairing(names=[SIM_NAME])
    udid = ensure_sim(SIM_NAME, RUNTIMES[ios], log)
    st["udid"] = udid
    save(st)
    m.launch(timeout=180)
    log(f"Mac up pid {m.pid}, hostd {m.wait_hostd(180)}")
    s = _sim(st)
    j = Journey(s, m, ev_dir(), ios_app, log)
    steps = j.run(only={"fresh_install", "sign_in", "choose_space", "mac_discovered"} if fresh else {"mac_discovered"})
    log(f"setup: {[(x['id'], x['status']) for x in steps]}")
    return steps


def relaunch_mac():
    m = _mac()
    m.quit()
    m.launch(timeout=180)
    return m.wait_hostd(180)


def down(delete_sim=False):
    st = load()
    perf_stop()
    rec_stop()
    m = _mac(st)
    log(f"Mac quit: {m.quit()}")
    if delete_sim and st.get("udid"):
        sh("xcrun", "simctl", "shutdown", st["udid"])
        sh("xcrun", "simctl", "delete", st["udid"])


# ---- phone ---------------------------------------------------------------
def shot(name):
    s = _sim()
    p = os.path.join(ev_dir(), "shots", f"{name}.png")
    sh("xcrun", "simctl", "io", s.udid, "screenshot", p)
    return p


def tap(x, y):
    _sim().tap(x, y)


def press(x, y, seconds=1.0):
    _sim().long_press(x, y, seconds)


def swipe(x1, y1, x2, y2, duration=0.4):
    _sim().swipe(x1, y1, x2, y2, duration)


def typ(text):
    sh("axe", "type", text, "--udid", load()["udid"])


def key(code):
    sh("axe", "key", str(code), "--udid", load()["udid"])


def tree(contains=None, limit=80):
    out = []
    for e in _sim().tree():
        if contains and contains.lower() not in (f"{e.label} {e.ident} {e.value}").lower():
            continue
        out.append(f"{e.kind:12} {e.frame} id={e.ident!r} label={str(e.label)[:70]!r} value={str(e.value)[:40]!r}")
    print("\n".join(out[:limit]))
    return len(out)


def find(**q):
    return _sim().find(**q)


def tapq(timeout=10, **q):
    return _sim().tap_q(timeout=timeout, **q)


def ocr(min_y=0, max_y=900):
    rows = [r for r in _sim().ocr() if min_y <= r[1] <= max_y]
    for x, y, w, h, t in rows:
        print(f"{x:5.0f} {y:5.0f} {w:4.0f} {h:3.0f}  {t}")
    return rows


def ocr_text():
    return " ".join(r[4] for r in _sim().ocr())


def app_pid():
    st = load()
    r = sh("pgrep", "-f", f"{st['udid']}.*CmuxMobileApp.app/CmuxMobileApp")
    pids = [int(p) for p in r.stdout.split()]
    return pids[0] if pids else None


def launch_app(env=None):
    st = load()
    _sim().launch(st["bundle"], env=env or {})


def terminate_app():
    st = load()
    sh("xcrun", "simctl", "terminate", st["udid"], st["bundle"])


def background(seconds=None):
    """Home button (the app goes to the background); with `seconds`, back after that."""
    s = _sim()
    s.home()
    if seconds:
        time.sleep(seconds)
        launch_app()


# ---- recording ------------------------------------------------------------
def rec_start(name):
    st = load()
    path = os.path.join(ev_dir(), f"{name}.mp4")
    p = subprocess.Popen(["xcrun", "simctl", "io", st["udid"], "recordVideo", "--codec", "h264", "--force", path],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    st["rec"] = {"pid": p.pid, "path": path}
    save(st)
    time.sleep(1.2)
    return path


def rec_stop():
    st = load()
    r = st.pop("rec", None)
    save(st)
    if not r:
        return None
    try:
        os.kill(r["pid"], signal.SIGINT)
    except ProcessLookupError:
        return r["path"]
    for _ in range(80):
        try:
            os.kill(r["pid"], 0)
            time.sleep(0.25)
        except ProcessLookupError:
            break
    return r["path"]


# ---- perf -----------------------------------------------------------------
PERF_SCRIPT = r'''
import json, subprocess, sys, time
pid, out, period = int(sys.argv[1]), sys.argv[2], float(sys.argv[3])
f = open(out, "a")
while True:
    r = subprocess.run(["ps", "-o", "%cpu=,rss=,time=", "-p", str(pid)], capture_output=True, text=True)
    if r.returncode:
        break
    cpu, rss, t = r.stdout.split()
    f.write(json.dumps({"t": time.time(), "cpu": float(cpu), "rss_mb": int(rss) / 1024, "cputime": t}) + "\n")
    f.flush()
    time.sleep(period)
'''


def perf_start(label, period=0.5):
    """Samples the phone app's CPU % and resident memory every `period` s into perf/<label>.jsonl."""
    perf_stop()
    st = load()
    pid = app_pid()
    d = os.path.join(ev_dir(), "perf")
    os.makedirs(d, exist_ok=True)
    out = os.path.join(d, f"{label}.jsonl")
    if os.path.exists(out):
        os.remove(out)
    p = subprocess.Popen([sys.executable, "-c", PERF_SCRIPT, str(pid), out, str(period)], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    st["perf"] = {"pid": p.pid, "out": out, "label": label, "t0": time.time()}
    save(st)
    return out


def perf_stop():
    st = load()
    p = st.pop("perf", None)
    save(st)
    if not p:
        return None
    try:
        os.kill(p["pid"], signal.SIGTERM)
    except ProcessLookupError:
        pass
    return perf_summary(p["out"])


def perf_summary(path):
    rows = [json.loads(line) for line in open(path)] if os.path.exists(path) else []
    if not rows:
        return {"n": 0}
    cpu = sorted(r["cpu"] for r in rows)
    mem = [r["rss_mb"] for r in rows]

    def pct(v, p):
        return v[min(len(v) - 1, int(p * len(v)))]
    s = {"label": os.path.basename(path)[:-6], "n": len(rows), "seconds": round(rows[-1]["t"] - rows[0]["t"], 1),
         "cpu_p50": pct(cpu, 0.5), "cpu_p95": pct(cpu, 0.95), "cpu_max": cpu[-1],
         "rss_start_mb": round(mem[0], 1), "rss_end_mb": round(mem[-1], 1), "rss_max_mb": round(max(mem), 1)}
    json.dump(s, open(path[:-6] + ".summary.json", "w"), indent=2)
    return s


def sample(seconds=5, name="sample"):
    """`sample` of the phone app (a host process on this Mac): the main thread's hot stacks."""
    out = os.path.join(ev_dir(), "perf", f"{name}.sample.txt")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    sh("sample", str(app_pid()), str(seconds), "-file", out, timeout=seconds + 60)
    return out


# ---- Mac side -------------------------------------------------------------
def mac_cli(*args, json_out=False, check=False):
    return _mac().cmux(*args, json_out=json_out, check=check)


def acpmux(*args, timeout=60):
    m = _mac()
    env = dict(os.environ, ACPMUX_HOME=ACPMUX_HOME)
    r = subprocess.run([os.path.join(m.app, "Contents/Resources/bin/acpmux"), *args], cwd=WORK, env=env,
                       capture_output=True, text=True, timeout=timeout)
    return r


def mac_shot(name):
    """The rig Mac's own window snapshot (debug socket), never a screen grab."""
    p = os.path.join(ev_dir(), "shots", f"mac-{name}.png")
    debug("debug.window_snapshot", {"path": p, "kind": "main"})
    return p


DEBUG_CALL = r'''
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall((json.dumps({"id": "1", "method": sys.argv[2], "params": json.loads(sys.argv[3])}) + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    d = s.recv(1 << 20)
    if not d: break
    buf += d
print(buf.decode())
'''


def debug(method, params=None, timeout=60):
    m = _mac()
    r = subprocess.run([sys.executable, "-c", DEBUG_CALL, m.socket, method, json.dumps(params or {})],
                       capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {"raw": r.stdout, "err": r.stderr}


def bg(fn, *a):
    """Runs fn in a thread (a Mac-side action while the phone is driven)."""
    t = threading.Thread(target=fn, args=a, daemon=True)
    t.start()
    return t
