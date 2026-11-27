"""VERIFY-round6 helpers (fresh verifier). Every command goes in on the phone
(composer paste + Send, or taps/swipes through axe). The Mac is used only for
oracle reads and the hostd kill. Events (with the laptop load) go to
verify8/events.jsonl.
"""
import json
import os
import re
import subprocess
import sys
import time

import tq
from tq import ctx, load, rsh, log

V6 = os.path.abspath(os.path.join(tq.HERE, "../design/terminal/verify8"))
RAW6 = os.path.expanduser("~/cmux-next-ios-e2e/termqa-raw/tv8")
RIG_HOSTD = "cmux-mobile-e2e-604fc689.app/Contents/Resources/bin/cmux-mobile-host"
U = load()["udid"]
os.makedirs(V6, exist_ok=True)
os.makedirs(RAW6, exist_ok=True)
tq.RAW = RAW6


def loads():
    return [float(x) for x in subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip("{} \n").split()]


def ev(kind, **kw):
    rec = {"t": round(time.time(), 3), "hms": time.strftime("%H:%M:%S"), "kind": kind, "load": loads(), **kw}
    with open(os.path.join(V6, "events.jsonl"), "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(json.dumps(rec), flush=True)
    return rec


def shot(name):
    raw = os.path.join(RAW6, f"{name}.png")
    subprocess.run(["xcrun", "simctl", "io", U, "screenshot", raw], capture_output=True)
    out = os.path.join(V6, f"{name}.jpg")
    subprocess.run(["sips", "-Z", "874", "-s", "format", "jpeg", "-s", "formatOptions", "70", raw, "--out", out], capture_output=True)
    return raw


def applog(start, path, pred=None):
    pred = pred or 'subsystem == "dev.cmux.mobile" AND (category == "terminal-sizing" OR category == "terminal" OR category == "link" OR category == "frames")'
    with open(path, "w") as f:
        subprocess.run(["xcrun", "simctl", "spawn", U, "log", "show", "--start", start, "--style", "compact", "--predicate", pred],
                       stdout=f, stderr=subprocess.DEVNULL)
    return path


def ocr_rows(lo=60, hi=900):
    s = tq.Sim(U)
    rows = [(round(y), t) for x, y, w, h, t in s.ocr() if lo <= y <= hi]
    rows.sort()
    return rows


def ids(rows, pat=r"(HIST|GEN|ROW)-?(\d+)"):
    out = []
    for _, t in rows:
        m = re.search(pat, t)
        if m:
            out.append(m.group(0))
    return out


def jump_button():
    s = tq.Sim(U)
    e = s.find(label="Scroll to bottom")
    return e[0] if e else None


def kill_hostd():
    t = time.time()
    rsh(f"pkill -9 -f '{RIG_HOSTD}'")
    return t


def hostd_events(since):
    """`starting` and `link up` lines in the rig's hostd log after `since` (epoch)."""
    r = rsh("tail -n 400 ~/Library/Application\\ Support/com.cmuxterm.app.debug.cmuxMobile.e2e.604fc689/cmux-mobile-host/cmux-mobile-host.log")
    out = []
    import datetime
    for line in r.stdout.splitlines():
        m = re.match(r"(\S+Z)", line)
        if not m:
            continue
        try:
            ts = datetime.datetime.strptime(m.group(1)[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc).timestamp()
        except ValueError:
            continue
        if ts >= since and ("link up" in line or "starting" in line or "link down" in line):
            out.append((round(ts - since, 2), line[30:150]))
    return out


def clear_composer():
    s = tq.Sim(U)
    for _ in range(4):
        f = s.find(ident="terminal.composer.field")
        if not f or not (f[0].value or "").strip() or (f[0].value or "").startswith("Send to"):
            return True
        tq.composer_clear()
    return False


def interrupt():
    """^C from the key bar (keyboard up), then hide the keyboard."""
    s, m, j = ctx()
    f = s.find(ident="terminal.composer.field")
    s.tap_el(f[0]); time.sleep(0.8)
    j.keybar("Control C"); time.sleep(0.5)
    j.keybar("Control C"); time.sleep(0.5)
    j.hide_keyboard()
