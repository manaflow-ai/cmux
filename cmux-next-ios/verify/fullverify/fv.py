#!/usr/bin/env python3
"""Fresh-verifier phone driver (verify/full-verify-app-20261019.md). Runs ON the rig mini
(mini-cmuxs-mac-mini-2) next to rmac.py and the e2e modules, one command per call:

    fv.py setup                      create/boot the one simulator (cmux-mobile-fv-1)
    fv.py install [--fresh]          install the Demo app (fresh: uninstall + keychain reset)
    fv.py launch | terminate
    fv.py ls [needle]                visible AX elements (kind, label, id, value, frame)
    fv.py tap  (--label L|--ident I|--contains C|--prefix P) [--kind K] [--idx N]
    fv.py press/long/tapxy X Y [SECONDS]
    fv.py swipe X1 Y1 X2 Y2 [DUR]
    fv.py type TEXT                  software keyboard taps (falls back to axe type)
    fv.py shot NAME                  screenshot to evidence/shots/NAME.png
    fv.py rec start NAME | rec stop  simctl recordVideo (detached, pid file)
    fv.py ocr [needle]

Every phone action is a real HID tap or typed text through AXe; nothing reaches the
app any other way.
"""
import json
import os
import signal
import subprocess
import sys
import time

BASE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(BASE, "e2e"))
os.environ["PATH"] = os.path.join(BASE, "bin") + ":/opt/homebrew/bin:" + os.environ.get("PATH", "")
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
from sim import Sim  # noqa: E402

STATE = os.path.join(BASE, "fv-state.json")
EV = os.path.join(BASE, "evidence")
APP = os.path.join(BASE, "app/CmuxMobileApp.app")
BUNDLE = "dev.cmux.mobile"
SIM_NAME = os.environ.get("FV_SIM", "cmux-mobile-fixr1-1")


def st():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def sim():
    return Sim(st()["udid"], os.path.join(EV, "shots"))


def run(*a, **k):
    return subprocess.run(list(a), capture_output=True, text=True, **k)


def query(args):
    q, kind, idx = {}, None, 0
    it = iter(args)
    for a in it:
        if a == "--label": q["label"] = next(it)
        elif a == "--ident": q["ident"] = next(it)
        elif a == "--contains": q["contains"] = next(it)
        elif a == "--prefix": q["prefix"] = next(it)
        elif a == "--kind": kind = next(it)
        elif a == "--idx": idx = int(next(it))
    if kind:
        q["kind"] = kind
    return q, idx


def visible(e):
    x, y, w, h = e.frame
    return w > 0 and h > 0 and x + w > 0 and x < 402 and y + h > 0 and y < 874


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "setup":
        lst = json.loads(run("xcrun", "simctl", "list", "devices", "-j").stdout)
        udid = next((d["udid"] for devs in lst["devices"].values() for d in devs if d["name"] == SIM_NAME), None)
        if not udid:
            udid = run("xcrun", "simctl", "create", SIM_NAME, "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                       "com.apple.CoreSimulator.SimRuntime.iOS-26-3").stdout.strip()
        run("xcrun", "simctl", "boot", udid)
        run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=600)
        s = st(); s["udid"] = udid
        json.dump(s, open(STATE, "w"), indent=2)
        print(udid)
    elif cmd == "install":
        s = sim()
        if "--fresh" in args:
            s.terminate(BUNDLE)
            run("xcrun", "simctl", "uninstall", s.udid, BUNDLE)
            run("xcrun", "simctl", "keychain", s.udid, "reset")
        r = run("xcrun", "simctl", "install", s.udid, APP)
        print("installed" if r.returncode == 0 else r.stderr)
    elif cmd == "launch":
        # FV_ENV: launch variables for the app as JSON (e.g. {"CMUX_MOBILE_FRAMELOG": "1"}).
        print(sim().launch(BUNDLE, env=json.loads(os.environ.get("FV_ENV", "{}"))))
    elif cmd == "terminate":
        sim().terminate(BUNDLE)
    elif cmd == "ls":
        needle = (args[0].lower() if args else None)
        for e in sim().tree():
            if not visible(e) or e.kind in ("Application",) or (e.kind == "Group" and not e.label and not e.ident) or e.kind == "Slider":
                continue
            line = f"{e.kind:<12} {e.label!r:<44.44} id={e.ident or ''} v={str(e.value or '')[:40]!r} {tuple(round(v) for v in e.frame)}"
            if needle is None or needle in line.lower():
                print(line)
    elif cmd == "tap":
        q, idx = query(args)
        s = sim()
        hits = [e for e in s.find(**q) if visible(e)]
        if len(hits) <= idx:
            print(f"NOT FOUND {q}"); sys.exit(2)
        s.tap_el(hits[idx]); print(f"tapped {hits[idx]!r}")
    elif cmd == "wait":
        q, idx = query(args)
        e = sim().wait(timeout=float(os.environ.get("FV_TIMEOUT", "20")), **q)
        print(repr(e) if e else f"TIMEOUT {q}"); sys.exit(0 if e else 2)
    elif cmd == "tapxy":
        sim().tap(float(args[0]), float(args[1])); print("ok")
    elif cmd == "press":
        sim().press(float(args[0]), float(args[1])); print("ok")
    elif cmd == "long":
        sim().long_press(float(args[0]), float(args[1]), float(args[2]) if len(args) > 2 else 1.0); print("ok")
    elif cmd == "swipe":
        a = [float(v) for v in args]
        sim().swipe(a[0], a[1], a[2], a[3], a[4] if len(a) > 4 else 0.4); print("ok")
    elif cmd == "drag":
        a = [float(v) for v in args]
        sim().drag(a[0], a[1], a[2], a[3], a[4] if len(a) > 4 else 1.0); print("ok")
    elif cmd == "type":
        sim().softtype(" ".join(args)); print("typed")
    elif cmd == "hwtype":
        run("axe", "type", " ".join(args), "--udid", sim().udid); print("typed (hw)")
    elif cmd == "key":
        run("axe", "key", args[0], "--udid", sim().udid); print("key")
    elif cmd == "shot":
        print(sim().shot(args[0]))
    elif cmd == "rec":
        os.makedirs(os.path.join(EV, "video"), exist_ok=True)
        pidf = os.path.join(BASE, "rec.pid")
        if args[0] == "start":
            path = os.path.join(EV, "video", args[1] + ".mp4")
            log = open(os.path.join(BASE, "rec.log"), "w")
            p = subprocess.Popen(["xcrun", "simctl", "io", st()["udid"], "recordVideo", "--codec", "h264", "--force", path],
                                 stdout=log, stderr=log, start_new_session=True)
            open(pidf, "w").write(f"{p.pid} {path}")
            print(f"recording {path} pid {p.pid}")
        else:
            if os.path.exists(pidf):
                pid, path = open(pidf).read().split(" ", 1)
                try:
                    os.kill(int(pid), signal.SIGINT)
                except ProcessLookupError:
                    pass
                for _ in range(100):
                    try:
                        os.kill(int(pid), 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.2)
                os.remove(pidf)
                print(path, os.path.getsize(path) if os.path.exists(path) else "missing")
    elif cmd == "ocr":
        needle = args[0].lower() if args else None
        for o in sim().ocr():
            if needle is None or needle in o[4].lower():
                print(f"{o[0]:.0f},{o[1]:.0f} {o[2]:.0f}x{o[3]:.0f} {o[4]}")
    else:
        sys.exit(f"unknown {cmd}")


if __name__ == "__main__":
    main()
