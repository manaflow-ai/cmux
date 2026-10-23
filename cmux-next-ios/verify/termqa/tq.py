"""Terminal QA driver (feat-cnx-ios-termqa): the iOS app in a headless simulator on
this laptop, the real tagged cmux-next Mac app on ANOTHER machine (a cmux Mac mini).
Every scenario goes phone app -> real link (WebRTC / WireGuard, direct or relay) ->
cmux-mobile-host -> daemon. The Mac side is driven only to start programs and to read its
screen for comparison (its bundled CLI over ssh on the mini, never from the phone).

    python3 -c 'from tq import *; ...'

State: ~/cmux-next-ios-e2e/termqa-state.json (udid, remote host, app path).
"""
import json
import os
import shlex
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
from sim import Sim  # noqa: E402
from journey import Journey  # noqa: E402

# TQ_STATE / TQ_HOST / TQ_RBASE / TQ_RAW select a rig instance (default: the shared rig on mini-2).
STATE = os.path.expanduser(os.environ.get("TQ_STATE", "~/cmux-next-ios-e2e/termqa-state.json"))
ART = os.path.join(HERE, "artifacts")
RAW = os.path.expanduser(os.environ.get("TQ_RAW", "~/cmux-next-ios-e2e/termqa-raw"))
HOST = os.environ.get("TQ_HOST", "mini-cmuxs-mac-mini-2")
RBASE = os.environ.get("TQ_RBASE", "~/cmux-next-ios-e2e/termqa")
BUNDLE = os.environ.get("TQ_BUNDLE", "dev.cmux.mobile")  # a tagged Demo build: dev.cmux.mobile.<tag>


def load():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def save(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump(st, open(STATE, "w"), indent=2)


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def rsh(cmd, timeout=180, check=False):
    argv = ["bash", "-lc", cmd] if HOST == "local" else ["ssh", "-o", "ConnectTimeout=10", HOST, cmd]
    r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, cwd=os.path.expanduser("~"))
    if check and r.returncode:
        raise RuntimeError(f"{HOST}: {cmd[:120]}: {(r.stderr or r.stdout)[-400:]}")
    return r


class RemoteMac:
    """The Mac half, on HOST. Same surface the rig's Journey uses."""

    def __init__(self):
        self.pid = None
        self._name = None
        self.tag = "cmux-mobile-e2e-604fc689"

    def _rmac(self, *args, timeout=180):
        return rsh(f"cd {RBASE} && python3 rmac.py " + " ".join(shlex.quote(a) for a in args), timeout=timeout)

    def cmux(self, *args, check=True, timeout=60, json_out=False):
        a = (["--json"] if json_out else []) + list(args)
        r = self._rmac("cli", *a, timeout=timeout + 20)
        if check and r.returncode != 0:
            raise RuntimeError(f"cmux {' '.join(args)}: {(r.stderr or r.stdout).strip()[:400]}")
        if json_out and r.returncode == 0:
            out = r.stdout.strip()
            try:
                return json.loads(out) if out else None
            except ValueError:
                return [json.loads(l) for l in out.splitlines() if l.strip()]
        return r

    def launch(self):
        d = json.loads(self._rmac("launch", timeout=300).stdout)
        self.pid = d["pid"]
        return time.time()

    def wait_hostd(self, timeout=120):
        return bool(json.loads(self._rmac("hostd").stdout)["hostd"])

    def quit(self):
        return json.loads(self._rmac("quit").stdout)["quit"]

    def computer_name(self):
        if not self._name:
            self._name = self._rmac("name").stdout.strip()
        return self._name

    def device_id(self):
        return self._rmac("device-id").stdout.strip() or None

    def link_events(self, since):
        # The mini's clock is NTP-synced like this one; good to ~0.1 s.
        return [tuple(x) for x in json.loads(self._rmac("link-events", str(since)).stdout or "[]")]


class LocalMac:
    """TQ_HOST=local: the hidden laptop rig (real Codex needs this laptop's codex login).
    The fleet-built app is used as built: its Info.plist is never edited and the
    bundle is never re-signed. Every setting goes in at launch with `open -g -j -n
    --env` (it overrides LSEnvironment), so the app is never activated or raised.
    TQ_RBASE is the rig folder: mac/<app>, config/, secrets/, bin/."""

    def __new__(cls):
        from mac import Mac
        rig = os.path.expanduser(RBASE)

        class _Local(Mac):
            def prepare(self):
                # Mac.prepare's copy step re-signs; skip it by stamping the app as its own source.
                stamp = os.path.join(self.rig, "mac", ".source")
                open(stamp, "w").write(f"{os.path.realpath(self.app)} {os.path.getmtime(self.info)}")
                self.source_app = self.app
                return Mac.prepare(self)

            def launch(self, timeout=90):
                res = os.path.join(self.app, "Contents/Resources")
                self.launch_env = dict(self.launch_env, **{
                    "CMUX_BUNDLED_CLI_PATH": f"{res}/bin/cmux",
                    "CMUXD_UNIX_PATH": os.path.expanduser(f"~/Library/Application Support/cmux/cmuxd-dev-{self.tag}.sock"),
                    "CMUXTERM_REPO_ROOT": "",
                    "CMUX_NEXT_CONFIG_FILE": self.config,
                    "CMUX_AUTH_CREDENTIALS_FILE": self.creds,
                    "CMUX_NEXT_IPHONE_PAIRING_SEED": self.pairing_seed,
                })
                t0 = Mac.launch(self, timeout)
                return t0

        apps = [a for a in os.listdir(os.path.join(rig, "mac")) if a.endswith(".app")]
        m = _Local(rig, os.path.join(rig, "mac", apps[0]))
        m.pid = (m.main_pids() or [None])[0]
        return m


def ctx():
    st = load()
    sim = Sim(st["udid"], os.path.join(ART, "shots"))
    mac = LocalMac() if HOST == "local" else RemoteMac()
    import journey
    journey.BUNDLE = BUNDLE
    j = Journey(sim, mac, ART, st.get("app_path"), log)
    j.seed = st.get("seed", {})
    j.ws_name = st.get("ws_name", j.ws_name)
    return sim, mac, j


def shot(name):
    s = Sim(load()["udid"])
    os.makedirs(os.path.join(ART, "shots"), exist_ok=True)
    raw = f"/tmp/termqa-{name}.png"
    subprocess.run(["xcrun", "simctl", "io", s.udid, "screenshot", raw], capture_output=True)
    out = os.path.join(ART, "shots", f"{name}.jpg")
    subprocess.run(["sips", "-Z", "874", "-s", "format", "jpeg", "-s", "formatOptions", "70", raw, "--out", out],
                   capture_output=True)
    return out


def ocr_dump(min_y=0, max_y=900):
    s = Sim(load()["udid"])
    for x, y, w, h, t in s.ocr():
        if min_y <= y <= max_y:
            print(f"{x:5.0f} {y:5.0f} {w:4.0f} {h:3.0f}  {t}")


def ax(contains=None, ident=None, label=None):
    s = Sim(load()["udid"])
    for e in s.find(contains=contains, ident=ident, label=label):
        print(repr(e))


def _mac():
    return LocalMac() if HOST == "local" else RemoteMac()


def term():
    return load()["term"]


def mac_screen(t=None):
    return _mac().cmux("terminal", t or term(), "screen", "read", json_out=True).get("text", "")


def mac_write(text, t=None):
    _mac().cmux("terminal", t or term(), "write", "--text", text)


def rec_start(name):
    if load().get("rec"):
        rec_stop()
    # Only a recorder of THIS simulator (other agents record theirs).
    subprocess.run(["pkill", "-INT", "-f", f"io {load()['udid']} recordVideo"], capture_output=True)
    st = load()
    os.makedirs(RAW, exist_ok=True)
    path = os.path.join(RAW, f"{name}.mp4")
    p = subprocess.Popen(["xcrun", "simctl", "io", st["udid"], "recordVideo", "--codec", "h264", "--force", path],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    st["rec"] = {"pid": p.pid, "path": path, "t0": time.time()}
    save(st)
    time.sleep(1.5)
    if p.poll() is not None:
        raise RuntimeError(f"recordVideo exited ({p.returncode})")
    return path


def rec_stop():
    import signal
    st = load()
    r = st.pop("rec", None)
    save(st)
    if not r:
        return None
    try:
        os.kill(r["pid"], signal.SIGINT)
    except ProcessLookupError:
        return r["path"]
    for _ in range(60):
        try:
            os.kill(r["pid"], 0)
            time.sleep(0.25)
        except ProcessLookupError:
            break
    return r["path"]


def sheet(name, fps=4, cols=8, start=None, dur=None, width=200, crop=None):
    """Contact sheet of a recording (verify-ui-video style) into artifacts/sheets."""
    src = os.path.join(RAW, f"{name}.mp4")
    os.makedirs(os.path.join(ART, "sheets"), exist_ok=True)
    out = os.path.join(ART, "sheets", f"{name}-%02d.jpg")
    vf = (f"crop={crop}," if crop else "") + f"fps={fps},scale={width}:-1,tile={cols}x4"
    cmd = ["ffmpeg", "-v", "error", "-y"] + (["-ss", str(start)] if start is not None else []) + \
          (["-t", str(dur)] if dur else []) + ["-i", src, "-vf", vf, out]
    subprocess.run(cmd, check=True)
    return sorted(p for p in os.listdir(os.path.join(ART, "sheets")) if p.startswith(name))


def frames(name, fps=10, start=None, dur=None, width=402):
    src = os.path.join(RAW, f"{name}.mp4")
    d = os.path.join(RAW, "frames", name)
    os.makedirs(d, exist_ok=True)
    cmd = ["ffmpeg", "-v", "error", "-y"] + (["-ss", str(start)] if start is not None else []) + \
          (["-t", str(dur)] if dur else []) + ["-i", src, "-vf", f"fps={fps},scale={width}:-1", os.path.join(d, "f%04d.png")]
    subprocess.run(cmd, check=True)
    return d


def load_avg():
    return float(subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.split()[1])


def composer_send(text, send=True):
    """Types into the composer on the soft keyboard and taps Send (the user's path)."""
    s, _, j = ctx()
    if not s.find(ident="terminal.composer.field"):
        raise RuntimeError("no composer on screen")
    s.tap_q(ident="terminal.composer.field")
    time.sleep(0.6)
    s.dismiss_keyboard_intro()
    s.softtype(text)
    if send:
        return s.tap_q(ident="terminal.composer.send")


def direct_type(text):
    """Types straight into the terminal (tap the terminal, soft keyboard)."""
    s, _, j = ctx()
    j.focus_terminal()
    s.softtype(text)


def key(label):
    s, _, j = ctx()
    return j.keybar(label)


def hide_kb():
    s, _, j = ctx()
    j.hide_keyboard()


def composer_clear():
    s, _, _ = ctx()
    f = s.find(ident="terminal.composer.field")
    if not f:
        return
    n = len(f[0].value or "")
    if n == 0:
        return
    if not s.keyboard():
        s.tap_el(f[0]); time.sleep(0.6)
    k = s.keyboard()
    if "delete" in k:
        # Hold delete: iOS accelerates to word deletion.
        s.long_press(*k["delete"].center, seconds=min(6, 1 + n / 10))


def paste_composer(text, send=True):
    """Simulator pasteboard -> composer (edit menu Paste) -> Send: the person's paste path."""
    s, _, _ = ctx()
    subprocess.run(["xcrun", "simctl", "pbcopy", s.udid], input=text, text=True, check=True)
    f = s.wait(ident="terminal.composer.field", timeout=10)
    if not s.keyboard():
        s.tap_el(f); time.sleep(0.7)
    f = s.find(ident="terminal.composer.field")[0]
    s.tap_el(f); time.sleep(0.5)
    p = s.wait(label="Paste", timeout=3)
    if not p:
        s.long_press(*f.center, seconds=0.8); time.sleep(0.4)
        p = s.wait(label="Paste", timeout=3)
    if not p:
        raise RuntimeError("no Paste in the composer's edit menu")
    s.tap_el(p); time.sleep(0.5)
    allow = s.find(label="Allow Paste", kind="Button")
    if allow:
        s.tap_el(allow[0]); time.sleep(0.5)
    if send:
        return s.tap_q(ident="terminal.composer.send")


def max_item(text):
    import re
    nums = [int(m) for m in re.findall(r"(?m)^\s*(\d{1,4})\.(?:\s|$)", text)]
    return max(nums) if nums else None


def lag_probe(samples=12, gap=1.5):
    """Phone vs Mac: the highest 'N. ' item on each screen at (nearly) the same moment."""
    s = Sim(load()["udid"])
    out = []
    for _ in range(samples):
        t0 = time.time()
        mac = max_item(mac_screen())
        t1 = time.time()
        phone = max_item("\n".join(o[4] for o in s.ocr()))
        t2 = time.time()
        out.append((round(t0 % 1000, 1), mac, phone, round(t1 - t0, 2), round(t2 - t1, 2)))
        time.sleep(gap)
    return out


def compare_bottom(n=8):
    """The phone's last n terminal text rows (OCR, above the composer) vs the Mac screen's last n non-blank rows."""
    s = Sim(load()["udid"])
    comp = s.find(ident="terminal.composer.field")
    ymax = comp[0].frame[1] - 8 if comp else 760
    rows = [o for o in s.ocr() if 60 < o[1] < ymax]
    rows.sort(key=lambda o: o[1])
    phone = [o[4].strip() for o in rows][-n:]
    mac = [l.strip() for l in mac_screen().splitlines() if l.strip()][-n:]
    return phone, mac


def motion_stats(video, start=None, dur=None, bottom=0.8):
    r = subprocess.run([sys.executable, os.path.join(HERE, "motion.py"), video, "--bottom", str(bottom)]
                       + (["--start", str(start)] if start is not None else []) + (["--dur", str(dur)] if dur else []),
                       capture_output=True, text=True)
    lines = r.stdout.strip().splitlines()
    import re
    shifts = []
    for l in lines:
        m = re.match(r"\s*([\d.]+)s\s+shift\s+([+-]?[\d.]+)", l)
        if m:
            shifts.append((float(m.group(1)), float(m.group(2))))
    return {"summary": lines[-1] if lines else r.stderr[-300:], "down": [x for x in shifts if x[1] > 0],
            "moves": len(shifts)}


def suite(tag, prompt=None):
    """The core streaming scenarios on the current transport; returns a result dict and records videos."""
    s, m, j = ctx()
    res = {"tag": tag, "link": None}
    if prompt is None:
        prompt = ("Print the numbers 1 to 700 in your reply, one per line, as N. followed by a different sentence "
                  "about terminals, keyboards or networks each time. No tools.")
    if not s.find(ident="terminal.composer.field"):
        j.open_seed_workspace()
    paste_composer(prompt)
    time.sleep(1); j.hide_keyboard(); time.sleep(4)
    # A: following.
    v = rec_start(f"{tag}-a-follow"); time.sleep(20); rec_stop()
    res["follow"] = motion_stats(v, start=2)
    res["lag"] = lag_probe(5, 0.8)
    # B: reading while it streams.
    v = rec_start(f"{tag}-b-read"); T = time.time(); ev = []
    time.sleep(1.5)
    s.drag(201, 250, 201, 600, 0.6, 30, 0.2); ev.append(("hold1", time.time() - T)); time.sleep(8); ev.append(("hold1-end", time.time() - T))
    s.drag(201, 250, 201, 600, 0.6, 30, 0.2); ev.append(("hold2", time.time() - T)); time.sleep(8); ev.append(("hold2-end", time.time() - T))
    s.swipe(201, 200, 201, 750, 0.12); time.sleep(3)
    s.swipe(201, 200, 201, 750, 0.12); time.sleep(3)
    jb = s.find(label="Jump to bottom") or s.find(contains="bottom")
    if jb:
        s.tap_el(jb[0]); ev.append(("jump", time.time() - T))
    time.sleep(5)
    rec_stop()
    off = 1.5  # recording starts ~1.5 s before T
    holds = {}
    for name in ("hold1", "hold2"):
        a = dict(ev)[name] + off + 1.2
        b = dict(ev)[name + "-end"] + off
        holds[name] = motion_stats(v, start=a, dur=b - a)
    res["read_holds"] = holds
    res["jump_found"] = bool(jb)
    # C: keyboard while it streams.
    v = rec_start(f"{tag}-c-keyboard")
    for _ in range(2):
        s.tap_q(ident="terminal.composer.field"); time.sleep(3)
        j.hide_keyboard(); time.sleep(3)
    rec_stop()
    res["keyboard"] = motion_stats(v, start=1.5, bottom=0.35)
    # D: grid round trip.
    v = rec_start(f"{tag}-d-grid")
    for _ in range(2):
        s.tap_q(label="Tabs", kind="Button"); time.sleep(2.5)
        c = [e for e in s.find(kind="Button") if (e.label or "").startswith("e2e-t1")]
        if c:
            s.tap_el(c[0])
        time.sleep(3)
    rec_stop()
    time.sleep(3)
    res["bottom"] = compare_bottom(6)
    return res


def follow_run(tag, seconds=60, prompt=None):
    s, m, j = ctx()
    if not s.find(ident="terminal.composer.field"):
        j.open_seed_workspace()
    paste_composer(prompt or "Print the numbers 1 to 900 in your reply, one per line, as N. followed by a different sentence about terminals each time. No tools.")
    time.sleep(1); j.hide_keyboard(); time.sleep(3)
    v = rec_start(tag); time.sleep(seconds); rec_stop()
    return motion_stats(v, start=2)


def app_mem():
    s, m, j = ctx()
    pid = j.app_pid()
    if not pid:
        return None
    rss = int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0)
    fp = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    import re
    m2 = re.search(r"phys_footprint:\s*([\d.]+ \w+)", fp) or re.search(r"Footprint:\s*([\d.]+ \w+)", fp)
    return {"pid": pid, "rss_mb": round(rss / 1024, 1), "footprint": m2.group(1) if m2 else None, "t": time.strftime("%H:%M:%S")}


def lifecycle(tag):
    """Mid-stream: background 15 s and back; switch to t2 and back; kill cmux-mobile-host (link drop)."""
    s, m, j = ctx()
    res = {}
    paste_composer("Print the numbers 1 to 900 in your reply, one per line, as N. followed by a sentence about reliability. No tools.")
    time.sleep(1); j.hide_keyboard(); time.sleep(5)
    v = rec_start(f"{tag}-lifecycle")
    s.home(); time.sleep(15)
    s.launch(BUNDLE, terminate=False); time.sleep(6)
    res["after_background"] = compare_bottom(8)
    s.tap_q(label="Tabs", kind="Button"); time.sleep(2)
    c = [e for e in s.find(kind="Button") if (e.label or "").startswith("e2e-t2")]
    if c:
        s.tap_el(c[0])
    time.sleep(6)
    s.tap_q(label="Tabs", kind="Button"); time.sleep(2)
    c = [e for e in s.find(kind="Button") if (e.label or "").startswith("e2e-t1")]
    if c:
        s.tap_el(c[0])
    time.sleep(5)
    res["after_tab_switch"] = compare_bottom(8)
    rsh('pkill -9 -f "cmux-mobile-e2e-604fc689.app/Contents/Resources/bin/cmux-mobile-host"')
    time.sleep(12)
    res["after_link_drop"] = compare_bottom(8)
    rec_stop()
    res["motion"] = motion_stats(v, start=1.5)
    return res


def grid_garble(tag, trips=3):
    """Verifier R2 defect 1: a Codex turn, grid round trips mid-stream, then the phone's last rows vs the Mac's."""
    s, m, j = ctx()
    if not s.find(ident="terminal.composer.field"):
        j.open_seed_workspace()
    paste_composer("Explain in about 60 numbered short paragraphs how terminal emulators handle scroll regions. No tools.")
    time.sleep(1); j.hide_keyboard(); time.sleep(4)
    rec_start(tag)
    for _ in range(trips):
        s.tap_q(label="Tabs", kind="Button"); time.sleep(2)
        c = [e for e in s.find(kind="Button") if (e.label or "").startswith("e2e-t1")]
        if c:
            s.tap_el(c[0])
        time.sleep(4)
    # Wait for Codex to finish, then compare.
    for _ in range(60):
        if "Worked for" in mac_screen()[-600:] or "done" in mac_screen()[-300:]:
            break
        time.sleep(2)
    time.sleep(3)
    shot(tag)
    rec_stop()
    p, mm = compare_bottom(6)
    return p, mm
