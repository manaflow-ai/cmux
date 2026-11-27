"""Runs ON a cmux mini: the rich-push rig's one headless simulator (verify/push-matrix.md).

Real HID touches through AXe (never the host's keyboard or focus), `simctl push` with the
APNs bodies the real Mac host produced (apns-from-capture.ts), screenshots and video.

    python3 pushphone.py setup [--fresh]      # create + boot "richpush-phone", install, sign in (dev "42")
    python3 pushphone.py install              # reinstall the built app (keeps data)
    python3 pushphone.py push FILE            # simctl push FILE to the app
    python3 pushphone.py launch | terminate | background
    python3 pushphone.py shot NAME            # OUT/NAME.png
    python3 pushphone.py texts                # visible AX labels
    python3 pushphone.py find TEXT            # elements whose label contains TEXT
    python3 pushphone.py tap TEXT [--kind K] [--index N]
    python3 pushphone.py tapxy X Y | longpress X Y [SECONDS] | longpress-text TEXT [SECONDS]
    python3 pushphone.py swipe X1 Y1 X2 Y2
    python3 pushphone.py type TEXT            # taps on the software keyboard
    python3 pushphone.py faceid match|nomatch|enroll
    python3 pushphone.py record start NAME | record stop
    python3 pushphone.py pid | udid | log SECONDS [PREDICATE] | shutdown
"""
import json
import shlex
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode_26.6.app/Contents/Developer")
os.environ["PATH"] = os.path.expanduser("~/cnx-macnext/tools/bin") + ":" + os.environ["PATH"]
from journey import Journey  # noqa: E402
from sim import Sim  # noqa: E402

ROOT = os.path.expanduser("~/richpush-verify")
NAME = os.environ.get("PUSHRIG_PHONE", "richpush-phone")
BUNDLE = "dev.cmux.mobile"
APP = os.path.join(ROOT, "dd/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app")
OUT = os.environ.get("PUSHRIG_OUT", os.path.join(ROOT, "evidence"))
STATE = os.path.join(ROOT, "phone.json")


# Extra app launch arguments, e.g. `-cmuxMobile.live.mac.<team> <mac device id>` to pin this
# rig's Mac when another rig signed in to the same account is online too.
LAUNCH_ARGS = shlex.split(os.environ.get("PUSHPHONE_LAUNCH_ARGS", ""))


def sh(*a, check=True, timeout=120):
    r = subprocess.run(list(a), capture_output=True, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise SystemExit(f"{' '.join(a[:3])}: {(r.stderr or r.stdout).strip()[:300]}")
    return r.stdout


def udid(create=False):
    devs = json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))["devices"]
    for v in devs.values():
        for d in v:
            if d["name"] == NAME:
                return d["udid"]
    if not create:
        raise SystemExit(f"no simulator {NAME}")
    runtimes = [r for r in json.loads(sh("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
                if r["isAvailable"] and r["platform"] == "iOS"]
    return sh("xcrun", "simctl", "create", NAME, "iPhone 17 Pro", runtimes[-1]["identifier"]).strip()


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} {msg}", flush=True)


def matches(sim, text, kind=None, exact=False):
    hit = (lambda l: l.lower() == text.lower()) if exact else (lambda l: text.lower() in l.lower())
    out = [e for e in sim.tree() if hit(e.label or "") and (kind is None or e.kind == kind)]
    # An exact label first ("Allow" must never pick "Don't Allow").
    return sorted(out, key=lambda e: (e.label or "").lower() != text.lower())


def main():
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "setup":
        u = udid(create=True)
        sh("xcrun", "simctl", "boot", u, check=False)
        sh("xcrun", "simctl", "bootstatus", u, "-b", timeout=300)
        sim = Sim(u, shots_dir=OUT)
        j = Journey(sim, None, OUT, APP, log)
        if "--fresh" in args or not sh("xcrun", "simctl", "listapps", u, check=False).count(BUNDLE):
            j.s_fresh_install()
            j.s_sign_in()
            j.s_choose_space()
        else:
            sim.launch(BUNDLE, args=LAUNCH_ARGS)
        sim.shot("setup")
        print(json.dumps({"udid": u}))
        return
    u = udid()
    sim = Sim(u, shots_dir=OUT)
    if cmd == "install":
        sh("xcrun", "simctl", "install", u, APP)
    elif cmd == "push":
        print(sh("xcrun", "simctl", "push", u, BUNDLE, args[0]).strip())
    elif cmd == "launch":
        sim.launch(BUNDLE, args=LAUNCH_ARGS, terminate=False)
    elif cmd == "terminate":
        sh("xcrun", "simctl", "terminate", u, BUNDLE, check=False)
    elif cmd == "background":
        # Home: the app goes to the background (no host input).
        sh("axe", "button", "home", "--udid", u)
    elif cmd == "nc":
        # Notification Center from the home screen's first page: Home (twice lands on page 1), then a pull from the top edge.
        sh("axe", "button", "home", "--udid", u)
        time.sleep(0.8)
        sh("axe", "button", "home", "--udid", u)
        time.sleep(0.8)
        sim.swipe(100, 5, 100, 600)
        time.sleep(1.2)
    elif cmd == "expand":
        # The newest notification whose label contains TEXT, opened as its long look (Options → View: the
        # same long look a long press opens; AXe's long press does not reach SpringBoard's gesture).
        cells = [e for e in sim.tree() if e.get("AXUniqueId") == "ListCell" and args[0].lower() in (e.label or "").lower()]
        if not cells:
            raise SystemExit(f"no notification with {args[0]!r}")
        x, y, w, h = cells[0].frame
        sim.swipe(int(x + w - 40), int(y + h / 2), int(x + 60), int(y + h / 2))
        time.sleep(1.0)
        view = matches(sim, "View", "Button", exact=True)
        if not view:
            raise SystemExit("no View button after the swipe")
        sim.tap_el(view[0])
        time.sleep(2.5)
    elif cmd == "gotab":
        # A root tab (Home, Workspaces, Feed, Settings); the bar may be collapsed to one button.
        for _ in range(3):
            hit = matches(sim, args[0], "RadioButton", exact=True)
            if hit:
                sim.tap_el(hit[0])
                time.sleep(1.0)
                return
            sim.tap(52, 860)
            time.sleep(0.8)
        raise SystemExit(f"no tab {args[0]}")
    elif cmd == "shot":
        print(sim.shot(args[0]))
    elif cmd == "texts":
        print(json.dumps([e.label for e in sim.tree() if e.label], indent=0))
    elif cmd == "find":
        for e in matches(sim, args[0]):
            print(repr(e))
    elif cmd == "tap":
        kind = args[args.index("--kind") + 1] if "--kind" in args else None
        index = int(args[args.index("--index") + 1]) if "--index" in args else 0
        found = matches(sim, args[0], kind, exact="--exact" in args)
        if not found:
            raise SystemExit(f"not found: {args[0]}")
        sim.tap_el(found[index])
        print(repr(found[index]))
    elif cmd == "tapxy":
        sim.tap(float(args[0]), float(args[1]))
    elif cmd == "longpress":
        sim.long_press(float(args[0]), float(args[1]), float(args[2]) if len(args) > 2 else 1.2)
    elif cmd == "longpress-text":
        found = matches(sim, args[0])
        if not found:
            raise SystemExit(f"not found: {args[0]}")
        x, y = found[0].center
        sim.long_press(x, y, float(args[1]) if len(args) > 1 else 1.2)
        print(repr(found[0]))
    elif cmd == "swipe":
        sim.swipe(*[int(float(a)) for a in args[:4]])
    elif cmd == "type":
        sim.softtype(" ".join(args))
    elif cmd == "faceid":
        what = {"match": "com.apple.BiometricKit_Sim.fingerTouch.match",
                "nomatch": "com.apple.BiometricKit_Sim.fingerTouch.nomatch"}.get(args[0])
        if args[0] == "enroll":
            sh("xcrun", "simctl", "spawn", u, "notifyutil", "-s", "com.apple.BiometricKit.enrollmentChanged", "1")
            sh("xcrun", "simctl", "spawn", u, "notifyutil", "-p", "com.apple.BiometricKit.enrollmentChanged")
        else:
            what = what.replace("fingerTouch", "pearl")
            sh("xcrun", "simctl", "spawn", u, "notifyutil", "-p", what)
    elif cmd == "record":
        pidf = os.path.join(ROOT, "record.pid")
        if args[0] == "start":
            os.makedirs(OUT, exist_ok=True)
            path = os.path.join(OUT, f"{args[1]}.mp4")
            p = subprocess.Popen(["xcrun", "simctl", "io", u, "recordVideo", "--codec", "h264", "--force", path],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            open(pidf, "w").write(str(p.pid))
            print(path)
        else:
            pid = int(open(pidf).read())
            os.kill(pid, signal.SIGINT)
            os.remove(pidf)
            print("stopped")
    elif cmd == "pid":
        r = subprocess.run(["pgrep", "-f", f"{u}/data/Containers/Bundle/Application/.*/CmuxMobileApp.app/CmuxMobileApp"],
                           capture_output=True, text=True)
        print(r.stdout.strip())
    elif cmd == "udid":
        print(u)
    elif cmd == "log":
        pred = args[1] if len(args) > 1 else 'subsystem == "dev.cmux.mobile"'
        print(sh("xcrun", "simctl", "spawn", u, "log", "show", "--info", "--debug", "--last", f"{args[0]}s", "--style", "compact",
                 "--predicate", pred, timeout=120))
    elif cmd == "shutdown":
        sh("xcrun", "simctl", "shutdown", u, check=False)
        if "--delete" in args:
            sh("xcrun", "simctl", "delete", u, check=False)
    else:
        raise SystemExit(f"unknown {cmd}")


if __name__ == "__main__":
    main()
