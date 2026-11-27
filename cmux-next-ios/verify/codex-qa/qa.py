"""Interactive driver for the Codex-in-terminal-tabs QA pass, on top of the e2e rig.

The rig (verify/e2e/run.sh ... --keep) leaves the hidden Mac app and the simulator up;
this module reattaches to them so each scenario step is a short `python3 -c` call:

    python3 -c 'from qa import *; s,m,j=ctx(); shot("x"); ocr_dump()'

State (udid, Mac app, seeded ids) lives in ~/cmux-next-ios-e2e/codexqa-state.json.
Recording: rec_start(name) / rec_stop() keep the recorder pid in the state file, so a
recording spans several calls; frames(name) splits a video into <=402 px frames.
"""
import json
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
from sim import Sim  # noqa: E402
from mac import Mac  # noqa: E402
from journey import Journey  # noqa: E402

STATE = os.path.expanduser("~/cmux-next-ios-e2e/codexqa-state.json")
ART = os.path.join(HERE, "artifacts")
RAW = os.path.expanduser("~/cmux-next-ios-e2e/codexqa-raw")  # full-size videos, not committed


def load():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def save(st):
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump(st, open(STATE, "w"), indent=2)


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def ctx():
    st = load()
    sim = Sim(st["udid"], os.path.join(ART, "shots"))
    mac = Mac(st["rig"], st["mac_app"])
    mac.pid = (mac.main_pids() or [None])[0]
    j = Journey(sim, mac, ART, st.get("app_path"), log)
    j.seed = st.get("seed", {})
    j.ws_name = st.get("ws_name", j.ws_name)
    return sim, mac, j


def shot(name):
    s, _, _ = ctx()
    os.makedirs(os.path.join(ART, "shots"), exist_ok=True)
    raw = f"/tmp/codexqa-{name}.png"
    subprocess.run(["xcrun", "simctl", "io", s.udid, "screenshot", raw], capture_output=True)
    out = os.path.join(ART, "shots", f"{name}.jpg")
    subprocess.run(["sips", "-Z", "874", "-s", "format", "jpeg", "-s", "formatOptions", "70", raw, "--out", out],
                   capture_output=True)
    return out


def ocr_dump(min_y=0, max_y=900):
    s, _, _ = ctx()
    for x, y, w, h, t in s.ocr():
        if min_y <= y <= max_y:
            print(f"{x:5.0f} {y:5.0f} {w:4.0f} {h:3.0f}  {t}")


def ax(contains=None, ident=None):
    s, _, _ = ctx()
    for e in s.find(contains=contains, ident=ident):
        print(repr(e))


def term():
    return load()["term"]


def mac_screen(t=None):
    _, m, _ = ctx()
    return m.cmux("terminal", t or term(), "screen", "read", json_out=True).get("text", "")


def mac_write(text, t=None):
    _, m, _ = ctx()
    m.cmux("terminal", t or term(), "write", "--text", text)


def rec_start(name):
    st = load()
    os.makedirs(RAW, exist_ok=True)
    path = os.path.join(RAW, f"{name}.mp4")
    p = subprocess.Popen(["xcrun", "simctl", "io", st["udid"], "recordVideo", "--codec", "h264", "--force", path],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    st["rec"] = {"pid": p.pid, "path": path, "t0": time.time()}
    save(st)
    time.sleep(1.5)
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
        pass
    for _ in range(60):
        try:
            os.kill(r["pid"], 0)
            time.sleep(0.25)
        except ProcessLookupError:
            break
    return r["path"]


def frames(name, fps=4, start=None, dur=None):
    """Splits RAW/<name>.mp4 into <=402 px JPEG frames under artifacts/frames/<name>/ and a
    402 px wide, small mp4 copy under artifacts/video/<name>.mp4."""
    src = os.path.join(RAW, f"{name}.mp4")
    fdir = os.path.join(ART, "frames", name)
    os.makedirs(fdir, exist_ok=True)
    cut = (["-ss", str(start)] if start is not None else []) + (["-t", str(dur)] if dur is not None else [])
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *cut, "-i", src, "-vf", f"fps={fps},scale=402:-2",
                    "-q:v", "6", os.path.join(fdir, "f%03d.jpg")], check=True)
    vdir = os.path.join(ART, "video")
    os.makedirs(vdir, exist_ok=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *cut, "-i", src, "-vf", "scale=402:-2", "-r", "15",
                    "-c:v", "libx264", "-crf", "32", "-preset", "veryfast", "-an",
                    os.path.join(vdir, f"{name}.mp4")], check=True)
    return fdir


def load_avg():
    return os.getloadavg()[0]


# ---- rig pairing (mactry builds ask the person to Allow each phone on the Mac) ----------
# The rig app is hidden, and the Allow prompt is person-only. A DEBUG rig app instead
# trusts the phones its pairing seed names (CMUX_NEXT_IPHONE_PAIRING_SEED, set by
# e2e/mac.py prepare(); SECURITY.md "Test-only pairing seed"). The app reads the file
# when a phone asks, so nothing is quit, relaunched or re-signed, and paired-devices.json
# is never written by hand.
EVENTS = os.path.expanduser("~/cmux-next-ios-e2e/codexqa-hostd-events.jsonl")
SHIM = os.path.expanduser("~/cmux-next-ios-e2e/bin/cmux-mobile-host-tee")


def rig_launch():
    _, m, _ = ctx()
    if not m.main_pids():
        # An app built before the fleet bundled cmux-mobile-host in DEBUG builds runs the shim.
        bundled = os.path.exists(os.path.join(m.app, "Contents/Resources/bin/cmux-mobile-host"))
        env = [] if bundled else ["--env", f"CMUX_NEXT_MOBILE_HOST_BIN={SHIM}"]
        subprocess.run(["open", "-g", "-j", "-n", *env, m.app], check=True)
    for _ in range(120):
        if m.main_pids() and m.cmux("app", "ping", check=False, timeout=5).returncode == 0 and m.hostd_pids():
            return True
        time.sleep(0.5)
    return False


def rig_pair(names=(), ids=()):
    """Trust these simulator phones (names) or link device ids on the rig Mac; the
    phone's next link pairs without a prompt."""
    _, m, _ = ctx()
    m.seed_pairing(names=names, ids=ids)
    return list(names) + list(ids)


def sheet(name, fps=2, cols=6, start=None, dur=None, width=200):
    """Contact sheet of RAW/<name>.mp4 for review: artifacts/sheets/<name>.jpg (<=1200 px wide)."""
    src = os.path.join(RAW, f"{name}.mp4")
    out = os.path.join(ART, "sheets", f"{name}.jpg")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cut = (["-ss", str(start)] if start is not None else []) + (["-t", str(dur)] if dur is not None else [])
    n = int(subprocess.run(["ffprobe", "-v", "error", "-count_packets", "-select_streams", "v:0", "-show_entries",
                            "format=duration", "-of", "csv=p=0", src], capture_output=True, text=True).stdout.strip().split(".")[0] or 10)
    rows = max(1, min(8, ((dur or n) * fps + cols - 1) // cols))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *cut, "-i", src, "-vf",
                    f"fps={fps},scale={width}:-2,tile={cols}x{int(rows)}",
                    "-frames:v", "1", "-q:v", "5", out], check=True)
    return out
