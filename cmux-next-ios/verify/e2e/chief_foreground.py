#!/usr/bin/env python3
"""Mac Chief after the app comes back to the foreground (link-reliability-20261023.md,
"Chief after the background"). Runs on the simulator mini against the soak rig
(link_soak.py: a signed-in simulator of the TestFlight-config app, hidden rig Macs on
other minis, the real link).

    python3 -u chief_foreground.py --sim cmux-lrsoak --bundle dev.cmux.app.internal \
        --away 10,60,300 --out DIR [--send]

Opens Home > Chief, waits until Chief is usable (composer on screen, no unavailable or
"Connecting" line), then for each `--away` seconds: Home button, wait, back to the app.
Records every change of what the Chief screen says, and the time from the foreground
until Chief is usable again. With --send a short message goes out each time and must
show as sent (not "Not Delivered").
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from journey import Journey  # noqa: E402
from sim import Sim, sh  # noqa: E402

BUSY = ("Connecting", "Reconnecting", "offline", "isn't connected", "Trying", "didn't answer")


def udid_of(name):
    for devs in json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))["devices"].values():
        for d in devs:
            if d["name"] == name:
                return d["udid"]
    raise SystemExit(f"no simulator {name}")


def state(sim):
    """(usable, a one-line summary of what the Chief screen says)."""
    els = sim.tree()
    composer = [e for e in els if e.ident == "conversation.composer.text"]
    bar = [e for e in els if e.ident == "chief.unavailable.bar"]
    busy = sorted({(e.label or e.value or "")[:70] for e in els
                   if any(b in (e.label or "") or b in (e.value or "") for b in BUSY)})
    summary = f"composer={'yes' if composer else 'no'} bar={(bar[0].label or '')[:60] if bar else '-'} busy={busy}"
    return bool(composer) and not bar and not busy, summary


def wait_usable(sim, timeout, log):
    t0 = time.time()
    seen = []
    while time.time() - t0 < timeout:
        ok, summary = state(sim)
        if not seen or seen[-1][1] != summary:
            seen.append((round(time.time() - t0, 2), summary))
            log(f"  +{seen[-1][0]:.2f}s {summary}")
        if ok:
            return time.time() - t0, seen
        time.sleep(0.25)
    return None, seen


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sim", required=True)
    ap.add_argument("--bundle", required=True)
    ap.add_argument("--away", default="10,60,300")
    ap.add_argument("--out", required=True)
    ap.add_argument("--send", action="store_true")
    ap.add_argument("--freeze", action="store_true",
                    help="while away, stop the app's process (SIGSTOP), as iOS suspends it on a device; "
                         "the simulator otherwise keeps a background app running")
    ap.add_argument("--phone-log", default="info,cmux_mobile_link=debug")
    a = ap.parse_args()
    os.makedirs(os.path.join(a.out, "shots"), exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S', time.gmtime())} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    udid = udid_of(a.sim)
    sim = Sim(udid, shots_dir=os.path.join(a.out, "shots"))
    env = dict(os.environ, SIMCTL_CHILD_CMUX_MOBILE_LOG=a.phone_log)
    subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process",
                    f"--stderr={os.path.join(a.out, 'phone-stderr.log')}", udid, a.bundle], check=True, capture_output=True, env=env)
    # A workspace shown full screen (the app restores it) hides the tab bar: back out first.
    Journey(sim, None, a.out, None, log).back_to_list()
    home = sim.wait(label="Home", kind="RadioButton", timeout=30)
    if home:
        sim.tap_el(home)
    row = sim.wait(ident="home.chief", timeout=60) or sim.wait(contains="Chief", kind="Button", timeout=10)
    if not row:
        sim.shot("no-chief-row")
        raise SystemExit("no Chief row on Home")
    sim.tap_el(row)
    first, seen = wait_usable(sim, 120, log)
    sim.shot("chief-open")
    results = {"open_s": first, "open_seen": seen, "rounds": []}
    log(f"Chief usable after opening: {first}")
    for n, away in enumerate(int(x) for x in a.away.split(",")):
        sim.home()
        log(f"background for {away} s{' (process stopped)' if a.freeze else ''}")
        pid = None
        if a.freeze:
            time.sleep(1)
            r = subprocess.run(["pgrep", "-f", f"{udid}/.*/CmuxMobileApp.app/CmuxMobileApp"], capture_output=True, text=True)
            pid = (r.stdout.split() or [None])[0]
            if pid:
                os.kill(int(pid), 19)  # SIGSTOP
        time.sleep(away)
        if pid:
            os.kill(int(pid), 18)  # SIGCONT
        t_fg = time.time()
        subprocess.run(["xcrun", "simctl", "launch", udid, a.bundle], capture_output=True)
        took, seen = wait_usable(sim, 300, log)
        sim.shot(f"after-{away}s")
        sent = None
        if a.send and took is not None:
            text = f"{n}0{int(t_fg) % 100000}"
            sim.tap_q(ident="conversation.composer.text")
            sim.softtype(text)
            sim.tap_q(ident="conversation.composer.send")
            time.sleep(6)
            labels = " ".join((e.label or "") for e in sim.tree())
            sent = {"text": text, "on_screen": text in labels, "not_delivered": "Not Delivered" in labels}
            sim.shot(f"sent-{away}s")
        results["rounds"].append({"away_s": away, "usable_after_s": None if took is None else round(took, 2),
                                  "seen": seen, "sent": sent})
        log(f"away {away} s: usable after {took} s; sent {sent}")
    json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=2)


if __name__ == "__main__":
    main()
