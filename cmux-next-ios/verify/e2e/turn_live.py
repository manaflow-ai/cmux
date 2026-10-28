#!/usr/bin/env python3
"""Live WireGuard over TURN on the rig: TURN over UDP (Settings > Developer >
Relay only) against TURN over TLS (Block UDP), on the real link through
Cloudflare TURN, typed on the phone.

Run after e2e.py left a signed-in simulator and the rig Mac app running
(`--keep`):

    python3 -u turn_live.py --mac-app APP --udid UDID [--samples 8]

For each mode it records the phone's link line, the Mac's path label
(cmux-mobile-host's log), the link RTT the phone shows (sampled for 20 s), and
round trips of a command typed on the phone's soft keyboard: from the tap on
Send to its output on the Mac's terminal. Over TLS it also opens a browser
workspace from the phone and waits for example.com to render. Results:
verify/evidence/<date>/turn-live/<HHMMSS>/results.json.
"""
import argparse
import datetime
import json
import os
import random
import re
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from journey import Journey  # noqa: E402
from mac import Mac  # noqa: E402
from sim import Sim  # noqa: E402

CNX = os.path.abspath(os.path.join(HERE, "../.."))

MODES = (
    ("turn_udp", "settings.transport.relayOnly", "settings.transport.blockUDP",
     lambda lab: "TURN)" in lab and "TLS" not in lab),
    ("turn_tls", "settings.transport.blockUDP", "settings.transport.relayOnly",
     lambda lab: "TURN over TLS" in lab),
)


def summary(values):
    if not values:
        return {"n": 0}
    s = sorted(values)
    return {"n": len(s), "median": round(statistics.median(s), 1), "min": round(s[0], 1),
            "max": round(s[-1], 1), "p90": round(s[min(len(s) - 1, int(len(s) * 0.9))], 1)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--udid", required=True)
    ap.add_argument("--samples", type=int, default=8)
    ap.add_argument("--modes", default="turn_udp,turn_tls")
    a = ap.parse_args()
    stamp = datetime.datetime.now()
    out = os.path.join(CNX, "verify/evidence", stamp.strftime("%Y-%m-%d"), "turn-live", stamp.strftime("%H%M%S"))
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "run.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    rig = os.path.expanduser(f"~/cmux-next-ios-e2e/{os.path.basename(a.mac_app)[len('cmux DEV '):-4]}")
    mac = Mac(rig, a.mac_app)
    sim = Sim(a.udid, os.path.join(out, "shots"))
    j = Journey(sim, mac, out, None, log)

    def to_list():
        """Back to the Workspaces list by its Back buttons (the journey's own
        back_to_list taps a hidden sheet's Done on this app version)."""
        for _ in range(6):
            els = sim.tree()
            if any(e.ident == "workspaces.list" for e in els) and any(
                    e.label == "Workspaces" and e.kind == "RadioButton" for e in els):
                return
            j.hide_keyboard()
            back = [e for e in sim.find(kind="Button", elements=els)
                    if e.ident == "chevron.left" or e.label == "Back"]
            back = [e for e in back if 0 <= e.center[1] <= 874]
            if back:
                sim.tap_el(back[0])
            else:
                j.tab("Workspaces")
            time.sleep(1.0)

    j.back_to_list = to_list
    j.seed_mac()
    term = j.seed["term1"]
    results = {"mac_app": os.path.basename(a.mac_app), "modes": {}}
    j.settings_transport("WireGuard")
    wanted = set(a.modes.split(","))
    for mode, on, off, want in MODES:
        if mode not in wanted:
            continue
        log(f"=== {mode}")
        since = time.time()
        j.relay_toggle("0", off)
        before, after = j.relay_toggle("1", on)
        log(f"{on}: {before} -> {after}")
        status, connect_s, seen = j.wait_status(want, timeout=60)
        log(f"link line: {status!r} after {connect_s:.1f} s ({seen[:4]})")
        rtts, t = [], time.time()
        while time.time() - t < 20:
            m = re.search(r"(\d+) ms", j.link_status() or "")
            if m:
                rtts.append(int(m.group(1)))
            time.sleep(1.0)
        log(f"link RTT samples (ms): {rtts}")
        j.open_seed_workspace()
        trips = []
        for i in range(a.samples):
            marker = f"t{random.randint(100000, 999999)}"
            sim.tap_q(ident="terminal.composer.field")
            time.sleep(0.5)
            sim.dismiss_keyboard_intro()
            sim.softtype(f"echo {marker}")
            sent = time.time()
            sim.tap_q(ident="terminal.composer.send")
            # The command line and its output: the marker twice.
            while time.time() - sent < 15:
                if j.mac_screen(term).get("text", "").count(marker) >= 2:
                    trips.append((time.time() - sent) * 1000)
                    break
            log(f"  typed round trip {i + 1}: {trips[-1]:.0f} ms" if len(trips) == i + 1 else f"  round trip {i + 1}: none")
        sim.shot(f"terminal-{mode}")
        j.hide_keyboard()
        mac_path = j.mac_path(since)
        browser = None
        if mode == "turn_tls":
            try:
                browser = j.browser_over_link()
                log(f"browser: example.com rendered in {browser} s")
            except Exception as error:  # recorded, not fatal: the terminal result stands
                browser = f"failed: {error}"
                log(f"browser: {browser}")
        results["modes"][mode] = {
            "link_line": status, "connect_s": round(connect_s, 2), "mac_path": mac_path,
            "link_rtt_ms": summary(rtts), "typed_round_trip_ms": summary(trips), "browser": browser,
        }
        log(f"{mode}: {json.dumps(results['modes'][mode])}")
        j.back_to_list()
        j.relay_toggle("0", on)
    json.dump(results, open(os.path.join(out, "results.json"), "w"), indent=2)
    log(f"results -> {os.path.join(out, 'results.json')}")


if __name__ == "__main__":
    main()
