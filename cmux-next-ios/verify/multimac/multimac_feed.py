"""Two Macs, the Feed and Home over the real link (multi-Mac UX check).

One headless simulator runs the iOS app; two hidden rig Macs (rig.py, each with
acpmux's fake agent as its default harness) run on two minis, signed in to the
same dev account. The phone chooses the first Mac (Workspaces filter); the
second Mac's agent then asks a permission. The phone answers Deny from the Feed,
and the answer must reach the second Mac (its `acpmux pending` empties, read on
that Mac, never through the phone), with no "Not connected" on the card. Then
Home: each Chief says where it runs, and the Mac menu
shows the second Mac's Home (its Mac Chief moves there).

    python3 multimac_feed.py --app PATH --udid UDID --rig HOST --rig HOST [--out DIR] [--keep-install]

Writes DIR/results.json, DIR/run.log, DIR/shots/ and DIR/multimac-feed.mp4.
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
from journey import Fail, Journey, check  # noqa: E402
from sim import Sim  # noqa: E402


class Rig:
    def __init__(self, host):
        self.host = host

    def run(self, *args, timeout=90):
        cmd = "cd ~/multimac-rig && python3 rig.py " + " ".join(f"'{a}'" for a in args)
        return subprocess.run(["ssh", "-o", "ConnectTimeout=10", self.host, cmd], capture_output=True, text=True, timeout=timeout)

    def device_id(self):
        return self.run("device-id").stdout.strip()

    def name(self):
        r = subprocess.run(["ssh", self.host, "scutil --get ComputerName"], capture_output=True, text=True, timeout=30)
        return r.stdout.strip()

    def pending(self):
        return self.run("acpmux", "pending").stdout.strip()

    def last(self, session):
        return self.run("acpmux", "last", session).stdout.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--udid", required=True)
    ap.add_argument("--rig", action="append", required=True)
    ap.add_argument("--out", default=os.path.join(HERE, "evidence", time.strftime("%Y%m%d-%H%M%S") + "-feed"))
    ap.add_argument("--keep-install", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    rigs = [Rig(h) for h in a.rig]
    check(len(rigs) == 2, "two rigs")
    for rig in rigs:
        rig.device, rig.mac_name = rig.device_id(), rig.name()
        log(f"rig {rig.host}: device {rig.device}, name {rig.mac_name!r}")
    chosen, asker = rigs
    sim = Sim(a.udid, shots_dir=os.path.join(a.out, "shots"))
    j = Journey(sim, None, a.out, a.app, log)
    results = {"rigs": [{"host": r.host, "device": r.device, "name": r.mac_name} for r in rigs], "checks": {}}

    if not a.keep_install:
        j.s_fresh_install()
        j.s_sign_in()
        j.s_choose_space()
    log("signed in")
    video = os.path.join(a.out, "multimac-feed.mp4")
    sim.record_start(video)
    try:
        # 1. Choose the first Mac (the Workspaces filter links and focuses it), then show All Macs.
        j.back_to_list()
        sim.tap_q(ident="workspaces.filter", timeout=60)
        time.sleep(1.0)
        sim.tap_q(contains=chosen.mac_name, timeout=20)
        time.sleep(3.0)
        sim.tap_q(ident="workspaces.filter", timeout=20)
        time.sleep(1.0)
        sim.tap_q(label="All Macs", timeout=20)
        time.sleep(2.0)
        sim.shot("01-workspaces-both-macs")
        value = (sim.wait(ident="workspaces.filter", timeout=10) or None)
        log(f"workspaces filter: {value.value if value else None}")

        # 2. The other Mac's agent asks; the Feed lists it.
        before = asker.pending()
        log(f"{asker.host} pending before: {before!r}")
        if "git push" not in before:
            asker.run("ask", "ask: git push origin main")
            time.sleep(3.0)
            log(f"{asker.host} pending after ask: {asker.pending()!r}")
        j.tab("Feed")
        deny = sim.wait(label="Deny", kind="Button", timeout=90)
        check(deny, "the second Mac's permission card never showed a Deny button in the Feed")
        sim.shot("02-feed-ask-from-second-mac")
        t0 = time.time()
        sim.tap_el(deny)
        reached = False
        while time.time() - t0 < 40:
            if "git push" not in asker.pending():
                reached = True
                break
            time.sleep(0.5)
        elapsed = round(time.time() - t0, 2)
        time.sleep(1.5)
        texts = sim.texts()
        unsent = [t for t in texts if "Not connected" in t or "Nothing was sent" in t]
        sim.shot("03-feed-after-deny")
        reply = asker.last("fake")
        log(f"deny reached {asker.host}: {reached} in {elapsed} s; card errors {unsent}; agent's reply {reply!r}")
        results["checks"]["deny_reached_asking_mac"] = reached
        results["checks"]["deny_seconds"] = elapsed
        results["checks"]["card_errors"] = unsent
        results["checks"]["asking_mac_reply"] = reply
        results["checks"]["chosen_mac_pending"] = chosen.pending()

        # 3. Home: where each Chief runs.
        j.tab("Home")
        time.sleep(2.0)
        sim.shot("04-home-chiefs")
        pins = {e.ident: e.label for e in sim.find(ident="home.chief*")}
        log(f"home pins: {pins}")
        results["checks"]["home_pins_all"] = pins

        # 4. Home's Mac menu (whose Home shows): the second Mac.
        sim.tap_q(ident="home.mac", timeout=20)
        time.sleep(1.2)
        sim.shot("05-home-mac-menu")
        sim.tap_q(contains=asker.mac_name, timeout=20)
        time.sleep(6.0)
        sim.shot("06-home-second-mac")
        pins2 = {e.ident: e.label for e in sim.find(ident="home.chief*")}
        filt = sim.wait(ident="home.mac", timeout=10)
        log(f"home pins, second Mac: {pins2}; Mac menu {filt.value if filt else None}")
        results["checks"]["home_pins_second_mac"] = pins2
        results["checks"]["home_filter_value"] = filt.value if filt else None
    finally:
        sim.record_stop()
    c = results["checks"]
    ok = c.get("deny_reached_asking_mac") and not c.get("card_errors") \
        and any(asker.mac_name in (v or "") for v in c.get("home_pins_second_mac", {}).values())
    results["pass"] = bool(ok)
    results["video"] = video
    json.dump(results, open(os.path.join(a.out, "results.json"), "w"), indent=2)
    log("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    try:
        main()
    except Fail as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
