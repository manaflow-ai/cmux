#!/usr/bin/env python3
"""Many Chiefs on the iPhone's Home over the real link: none missing, none twice, in order.

A user reported that Home "doesn't paginate its Chiefs properly". The phone's Home reads
the Mac's whole `home-inbox` list in one reply (MacHomeFeed); this run checks that with
many Chiefs, scrolled end to end.

Runs ON a cmux mini, as chief_qa_live.py: the hidden rig Mac (mac.py) and the iOS app in
one headless simulator driven with AXe (accessibility reads and synthetic touches on that
simulator only; never Simulator.app, never the user's apps).

    python3 home_chiefs_paging_live.py --mac-app PATH --app PATH [--count 60] [--more 5]
                                       [--sim-name cmux-homepg] [--out DIR]

Scenarios:
- scroll_all:   N Chiefs made on the Mac; the phone's Home, scrolled from the top to the
                end, lists each exactly once, in the Mac's order (newest first).
- live_more:    with Home scrolled to the end, M more Chiefs are made on the Mac; back at
                the top each is listed once, and the earlier N are all still there.
Writes DIR/results.json, run.log, shots/, phone.mp4.
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "e2e"))
from e2e import CNX, RUNTIMES, ensure_sim  # noqa: E402
import journey  # noqa: E402
from journey import Journey  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from sim import Sim  # noqa: E402
from chief_delete_live import debug, mac_shot, wait_for  # noqa: E402
from chief_qa_live import records  # noqa: E402

PREFIX = "Pg "
ROW_PREFIXES = ("home.row.", "home.pin.", "home.chief.mac")


def visible_rows(sim):
    """Home's rows on screen now: (identifier, label, top y)."""
    return [(e.ident, e.label or "", e.frame[1]) for e in sim.tree() if e.ident and e.ident.startswith(ROW_PREFIXES)]


def sweep(sim, shot, tag, max_drags=80):
    """Scrolls Home from the top to the end and returns each row identifier in list order with its label.

    A row seen on several screens counts once (same identifier). A drag that shows no new row
    twice in a row is the end of the list."""
    to_top(sim)
    order, labels = [], {}
    still = 0
    for i in range(max_drags):
        new = 0
        for ident, label, _y in sorted(visible_rows(sim), key=lambda r: r[2]):
            if ident not in labels:
                labels[ident] = label
                order.append(ident)
                new += 1
        if i in (0, 3):
            shot(f"{tag}-page{i}")
        still = still + 1 if new == 0 else 0
        if still >= 2:
            break
        # Point-to-point with a hold: no fling, so each drag moves one screen less a margin.
        sim.drag(200, 700, 200, 260, duration=0.6, steps=30, hold=0.3)
        time.sleep(0.4)
    shot(f"{tag}-end")
    return order, labels


def to_top(sim):
    for _ in range(40):
        before = [r[0] for r in visible_rows(sim)][:1]
        sim.drag(200, 220, 200, 760, duration=0.25, steps=10, hold=0.1)
        time.sleep(0.2)
        if [r[0] for r in visible_rows(sim)][:1] == before:
            break


def main():  # noqa: C901 - one live run
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--sim-name", default="cmux-homepg")
    ap.add_argument("--ios", default="26", choices=sorted(RUNTIMES))
    ap.add_argument("--count", type=int, default=60)
    ap.add_argument("--more", type=int, default=5)
    ap.add_argument("--out")
    a = ap.parse_args()

    mac_app = os.path.abspath(a.mac_app)
    journey.BUNDLE = pb(os.path.join(a.app, "Info.plist"), "Print :CFBundleIdentifier")
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "home-chiefs-paging")
    shots = os.path.join(out, "shots")
    os.makedirs(shots, exist_ok=True)
    logf = open(os.path.join(out, "run.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    rig = os.path.expanduser(f"~/cmux-next-ios-e2e/{os.path.basename(mac_app)[len('cmux DEV '):-4]}")
    mac = Mac(rig, mac_app, cleanup=True, log=log).prepare()
    mac.seed_pairing(names=[a.sim_name])
    udid = ensure_sim(a.sim_name, RUNTIMES[a.ios], log)
    sim = Sim(udid, shots)
    subprocess.run(["xcrun", "simctl", "ui", udid, "appearance", "light"], capture_output=True)
    result = {"mac_app": os.path.basename(mac_app), "app": a.app, "simulator": f"{a.sim_name} {udid}",
              "count": a.count, "more": a.more, "scenarios": {}, "shots": {}}
    S = result["scenarios"]
    n_shot = [0]

    def shot(name):
        n_shot[0] += 1
        path = sim.shot(f"{n_shot[0]:02d}-{name}")
        result["shots"][name] = path
        return path

    def scenario(name, fn):
        log(f"== {name}")
        t0 = time.time()
        try:
            r = fn() or {}
            r.setdefault("pass", True)
        except Exception as e:  # noqa: BLE001 - a scenario's failure is its result
            r = {"pass": False, "error": f"{type(e).__name__}: {e}", "trace": traceback.format_exc()[-1500:]}
            try:
                shot(f"{name}-error")
            except Exception:  # noqa: BLE001
                pass
        r["seconds"] = round(time.time() - t0, 1)
        S[name] = r
        log(f"   {name}: {'PASS' if r.get('pass') else 'FAIL'} {json.dumps({k: v for k, v in r.items() if k != 'trace'})[:900]}")

    def make_chiefs(names):
        for name in names:
            mac.cmux("chief", "new", "--name", name, json_out=True)

    def check(order, labels, expected):
        """Each expected name once (by its row identifier), in the order the names were made, newest first."""
        seen = {}
        for ident in order:
            for name in expected:
                # A row's label starts with its name ("Pg 07 1712, Chief · …").
                if labels[ident].startswith(name + ",") or labels[ident] == name:
                    seen.setdefault(name, []).append(ident)
        missing = [n for n in expected if n not in seen]
        twice = {n: ids for n, ids in seen.items() if len(ids) > 1}
        listed = [n for ident in order for n in expected if seen.get(n, [None])[0] == ident]
        newest_first = list(reversed(expected))
        in_order = [n for n in listed] == [n for n in newest_first if n in seen]
        return {"rows_seen": len(order), "expected": len(expected), "missing": missing, "twice": twice,
                "in_order": in_order, "listed_first": listed[:5], "listed_last": listed[-5:]}

    try:
        mac.launch()
        log(f"Mac app up (pid {mac.pid}), host {'running' if mac.wait_hostd(180) else 'NOT running'}")
        for old in list(records(mac.cmux("chief", "list", json_out=True))):
            if str(old.get("display_name", "")).startswith(PREFIX):
                mac.cmux("chief", "delete", old["id"], check=False)
        run_id = time.strftime("%H%M")
        first = [f"{PREFIX}{i:02d} {run_id}" for i in range(1, a.count + 1)]
        t0 = time.time()
        make_chiefs(first)
        log(f"made {len(first)} Chiefs in {time.time() - t0:.0f}s")

        j = Journey(sim, mac, out, a.app, log)
        steps = j.run(only={"fresh_install", "sign_in", "choose_space", "mac_discovered"})
        if any(st["status"] != "pass" for st in steps):
            log("setup failed once; relaunching and retrying")
            sim.launch(journey.BUNDLE)
            steps = j.run(only={"choose_space", "mac_discovered"})[-2:]
        log(f"setup: {[(s['id'], s['status']) for s in steps]}")
        if any(st["status"] != "pass" for st in steps):
            raise RuntimeError(f"setup failed: {steps}")
        debug(mac, "action.run", {"action": "home.show", "origin": "script"})
        try:
            sim.record_start(os.path.join(out, "phone.mp4"))
        except RuntimeError as e:
            # A recorder that does not start (a loaded host) leaves the run its stills.
            result["recording"] = f"not started: {e}"
            log(f"recording: {e}; going on with stills")

        def scroll_all():
            j.tab("Home")
            ok, secs = wait_for(lambda: any(first[-1] in r[1] for r in visible_rows(sim)), 120)
            shot("home-top")
            mac_shot(mac, os.path.join(shots, "mac-home.png"))
            order, labels = sweep(sim, shot, "sweep1")
            r = check(order, labels, first)
            r["seconds_to_newest"] = secs
            r["pass"] = bool(ok) and not r["missing"] and not r["twice"] and r["in_order"]
            return r
        scenario("scroll_all", scroll_all)

        def live_more():
            # At the end of the list, the Mac makes more; the phone must list them without a touch.
            sweep(sim, shot, "before-more")
            more = [f"{PREFIX}{i:02d} {run_id}" for i in range(a.count + 1, a.count + a.more + 1)]
            make_chiefs(more)
            to_top(sim)
            ok, secs = wait_for(lambda: any(more[-1] in r[1] for r in visible_rows(sim)), 60)
            shot("after-more-top")
            order, labels = sweep(sim, shot, "sweep2")
            r = check(order, labels, first + more)
            r["seconds_new_listed"] = secs
            r["pass"] = bool(ok) and not r["missing"] and not r["twice"] and r["in_order"]
            return r
        scenario("live_more", live_more)
    finally:
        try:
            sim.record_stop()
        except Exception:  # noqa: BLE001
            pass
        try:
            for old in list(records(mac.cmux("chief", "list", json_out=True))):
                if str(old.get("display_name", "")).startswith(PREFIX):
                    mac.cmux("chief", "delete", old["id"], check=False)
        except Exception as e:  # noqa: BLE001
            log(f"cleanup: {e}")
        try:
            mac.teardown()
        except Exception as e:  # noqa: BLE001
            log(f"teardown: {e}")
        result["pass"] = bool(S) and all(s.get("pass") for s in S.values())
        with open(os.path.join(out, "results.json"), "w") as f:
            json.dump(result, f, indent=2)
        log(f"results: {'PASS' if result['pass'] else 'FAIL'} -> {out}")
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
