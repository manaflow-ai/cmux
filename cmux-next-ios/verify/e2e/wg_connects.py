"""Fresh WireGuard connects from a simulator to a hidden rig Mac, over the real link.

Runs on the simulator host against a hidden rig Mac (acceptance-latest-ci-20261021.md's
setup: the same TestFlight-config simulator app and pairing-seed name). Signs in once, then relaunches the app N times; each launch is a
fresh link. For each it records the phone's link line (the rig Mac's row on Settings >
Devices: "Connected · WireGuard relay (TURN) · 14 ms") and every change of it during
--watch seconds, with UTC times to match the Mac's cmux-mobile-host.log.

  python3 wg_connects.py --app CmuxMobileApp.app --bundle dev.cmux.app.internal \
      --sim acc-latest-ci-ios26 --runtime <iOS runtime id> --connects 3 --out DIR \
      [--block-udp]   # the rig's relay switch: SIMCTL_CHILD_CMUX_MOBILE_DEV_BLOCK_UDP=1
      [--reuse]       # keep the signed-in simulator of a previous run

Credentials: CMUX_MOBILE_STACK_EMAIL / CMUX_MOBILE_STACK_PASSWORD (never printed).
"""
import argparse
import datetime
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim import Sim, sh  # noqa: E402


DEVICE = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"


def ensure_sim(name, runtime):
    """A fresh headless simulator named `name` (the rig Mac's pairing seed names it)."""
    for devs in json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))["devices"].values():
        for d in devs:
            if d["name"] == name:
                sh("xcrun", "simctl", "delete", d["udid"], check=False)
    udid = sh("xcrun", "simctl", "create", name, DEVICE, runtime).strip()
    sh("xcrun", "simctl", "boot", udid)  # headless; Simulator.app is never opened
    sh("xcrun", "simctl", "bootstatus", udid, "-b", timeout=600)
    return udid


def utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%H:%M:%S.%f")[:-3]


def find_sim(name):
    for devs in json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))["devices"].values():
        for d in devs:
            if d["name"] == name:
                return d["udid"]
    return None


def onboard(sim, log):
    """Sign-in to the tab bar."""
    q = [dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"),
         dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")]
    i, _ = sim.wait_any(q, timeout=60)
    if i is None:
        raise SystemExit("the app never left the welcome screen in 60 s")
    if i in (0, 1):
        # The space the rig Mac is signed in to: a team row with a Mac online
        # (the Mac registers in the account's selected team), else Personal.
        sim.wait(ident="setup.teams.create", timeout=20)
        time.sleep(1.0)
        buttons = [b for b in sim.find(kind="Button") if b.ident not in ("setup.teams.personal", "setup.teams.create")]
        log("team step: " + " | ".join(repr(b.label) for b in buttons))
        online = [b for b in buttons if re.search(r"\b[1-9]\d* online", b.label or "", re.I)]
        e = online or sim.find(ident="setup.teams.personal") or sim.find(label="Not now", kind="Button")
        log(f"team step: picked {e[0].label!r}")
        sim.tap_el(e[0])
        time.sleep(1.0)
    if sim.find(contains="Connect your Mac"):
        deadline = time.time() + 90
        while time.time() < deadline:
            s = sim.find(ident="connect-mac.status")
            if s and "online" in (s[0].label or "").lower():
                break
            time.sleep(0.5)
        for _ in range(3):
            c = sim.wait(label="Continue", kind="Button", timeout=10)
            if not c:
                break
            time.sleep(0.8)
            sim.tap_el(c)
            time.sleep(1.5)
            if not sim.find(contains="Connect your Mac"):
                break
    if sim.find(label="Turn on notifications"):
        sim.tap_q(label="Not now", kind="Button")
    if not sim.wait(label="Workspaces", kind="RadioButton", timeout=30):
        raise SystemExit("never reached the tab bar")
    log("onboarded")


def link_line(sim):
    """The rig Mac's row on Settings > Devices: "<name>, <subtitle>, Connected · WireGuard direct · …"."""
    rows = sim.find(ident="settings.pairedMacs.*")
    for r in rows:
        label = r.label or ""
        for part in label.split(", "):
            if part.startswith(("Connected", "Connecting", "Reconnecting")) or "failed" in part:
                return label[label.index(part):]
    return ""


def open_devices(sim):
    t = sim.wait(label="Settings", kind="RadioButton", timeout=20)
    if t:
        sim.tap_el(t)
    d = sim.wait(ident="settings.devices", timeout=10)
    if d:
        sim.tap_el(d)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--sim", required=True)
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--connects", type=int, default=3)
    ap.add_argument("--watch", type=float, default=15.0, help="seconds to follow the line after Connected")
    ap.add_argument("--block-udp", action="store_true")
    ap.add_argument("--reuse", action="store_true")
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{utc()} {msg}"
        print(line, flush=True)
        logf.write(line + "\n"); logf.flush()

    env = {"CMUX_MOBILE_STACK_EMAIL": os.environ.get("CMUX_MOBILE_STACK_EMAIL", ""),
           "CMUX_MOBILE_STACK_PASSWORD": os.environ.get("CMUX_MOBILE_STACK_PASSWORD", "")}
    udid = find_sim(a.sim) if a.reuse else None
    if udid is None:
        # Only a new simulator signs in; a reused one is signed in already.
        if not all(env.values()):
            raise SystemExit("CMUX_MOBILE_STACK_EMAIL / CMUX_MOBILE_STACK_PASSWORD not set")
        udid = ensure_sim(a.sim, a.runtime)
        sh("xcrun", "simctl", "install", udid, a.app)
        sim = Sim(udid, shots_dir=os.path.join(a.out, "shots"))
        sim.launch(a.bundle, env=env)
        onboard(sim, log)
    sim = Sim(udid, shots_dir=os.path.join(a.out, "shots"))
    log(f"simulator {a.sim} {udid} block_udp={a.block_udp}")
    if a.block_udp:
        env["CMUX_MOBILE_DEV_BLOCK_UDP"] = "1"
    results = []
    for n in range(1, a.connects + 1):
        sim.terminate(a.bundle)
        time.sleep(1.0)  # the old process's link close reaches the Mac before the next dial
        start = time.time()
        log(f"connect {n}: launch")
        sim.launch(a.bundle, env=env)
        seen, connected_at = [], None
        deadline = start + 60
        # The link line is on Settings > Devices (one Mac: no status row in the list).
        open_devices(sim)
        while time.time() < deadline and (connected_at is None or time.time() < connected_at + a.watch):
            line = link_line(sim)
            if line and (not seen or seen[-1]["line"] != line):
                seen.append({"utc": utc(), "t": round(time.time() - start, 2), "line": line})
                log(f"connect {n}: +{seen[-1]['t']:.2f}s {line}")
            if connected_at is None and line.startswith("Connected"):
                connected_at = time.time()
            time.sleep(0.25)
        sim.shot(f"connect-{n}")
        results.append({"connect": n, "launch_utc": datetime.datetime.fromtimestamp(start, datetime.timezone.utc).isoformat(),
                        "connected_s": round(connected_at - start, 2) if connected_at else None, "lines": seen})
    with open(os.path.join(a.out, "results.json"), "w") as f:
        json.dump({"udid": udid, "block_udp": a.block_udp, "results": results}, f, indent=2)
    logf.close()


if __name__ == "__main__":
    main()
