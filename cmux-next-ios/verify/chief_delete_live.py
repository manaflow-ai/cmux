#!/usr/bin/env python3
"""Delete Chief on the Mac reaches the iPhone's Home over the real link.

Runs ON a cmux mini: the hidden e2e rig Mac (mac.py: its own bundle id, config and
credentials, launched with `open -g -j`, never activated) and the iOS app in one
headless simulator driven with AXe (accessibility taps on that simulator only).

    python3 chief_delete_live.py --mac-app PATH --app PATH [--sim-name cmux-chiefdel] [--out DIR]

Two Chiefs are made on the Mac (`cmux chief new`), each with its direct conversation.
1. Online: the phone's Home lists "Doomed Chief"; the Mac deletes it with its own
   Delete Chief action (`home.deleteChief`, the row menu's action); the row leaves the
   phone's Home with no touch on the phone.
2. Offline: the phone app is terminated; the Mac deletes "Gone While Away"; the phone
   app launches again and its Home never shows that row.
Each step stills the phone and the Mac (the Mac's own window snapshot). The simulator
is recorded for the whole run. Writes DIR/results.json, run.log, shots/, phone.mp4.
"""
import argparse
import datetime
import json
import os
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "e2e"))
from e2e import CNX, RUNTIMES, ensure_sim  # noqa: E402
import journey  # noqa: E402
from journey import Journey  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from sim import Sim  # noqa: E402

DEBUG_CALL = r'''
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall((json.dumps({"id": "1", "method": sys.argv[2], "params": json.loads(sys.argv[3])}) + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    d = s.recv(1 << 20)
    if not d: break
    buf += d
print(buf.decode())
'''


def debug(mac, method, params=None, timeout=60):
    r = subprocess.run([sys.executable, "-c", DEBUG_CALL, mac.socket, method, json.dumps(params or {})],
                       capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(r.stdout or "{}")
    except ValueError:
        return {"raw": r.stdout, "err": r.stderr}


def mac_shot(mac, path):
    debug(mac, "debug.window_snapshot", {"path": path, "kind": "main"})
    return path if os.path.exists(path) else None


def phone_titles(sim):
    """Home's rows as the phone shows them: each row's accessibility label."""
    return [e.label or "" for e in sim.tree() if e.ident and (e.ident.startswith(("home.row.", "home.pin.", "home.chief.mac")))]


def shows(sim, name):
    """Whether Home lists `name`; None while the tree has no rows (a read in the middle of a redraw)."""
    titles = phone_titles(sim)
    if not titles:
        return None
    return any(name in t for t in titles)


def gone(sim, name, hold=4.0):
    """`name` left Home and stays out for `hold` seconds, with other rows listed meanwhile."""
    end = time.time() + hold
    while time.time() < end:
        if shows(sim, name) is not False:
            return False
        time.sleep(0.4)
    return True


def wait_for(pred, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True, round(timeout - (deadline - time.time()), 1)
        time.sleep(0.5)
    return pred(), None


def main():  # noqa: C901 - one live scenario
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--sim-name", default="cmux-chiefdel")
    ap.add_argument("--ios", default="26", choices=sorted(RUNTIMES))
    ap.add_argument("--out")
    a = ap.parse_args()

    mac_app = os.path.abspath(a.mac_app)
    journey.BUNDLE = pb(os.path.join(a.app, "Info.plist"), "Print :CFBundleIdentifier")
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "chief-delete")
    shots = os.path.join(out, "shots")
    os.makedirs(shots, exist_ok=True)
    logf = open(os.path.join(out, "run.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n"); logf.flush()

    rig = os.path.expanduser(f"~/cmux-next-ios-e2e/{os.path.basename(mac_app)[len('cmux DEV '):-4]}")
    mac = Mac(rig, mac_app, cleanup=True, log=log).prepare()
    mac.seed_pairing(names=[a.sim_name])
    udid = ensure_sim(a.sim_name, RUNTIMES[a.ios], log)
    sim = Sim(udid, shots)
    result = {"mac_app": os.path.basename(mac_app), "app": a.app, "simulator": f"{a.sim_name} {udid}",
              "checks": {}, "shots": {}, "timings": {}}
    c = result["checks"]
    rec = None
    try:
        mac.launch()
        log(f"Mac app up (pid {mac.pid}), host {'running' if mac.wait_hostd(120) else 'NOT running'}")
        # Chiefs an earlier run left on this rig's Chief home go first (the CLI's own delete).
        def records(value):
            if isinstance(value, dict):
                if "id" in value and "display_name" in value:
                    yield value
                for v in value.values():
                    yield from records(v)
            elif isinstance(value, list):
                for v in value:
                    yield from records(v)
        for old in list(records(mac.cmux("chief", "list", json_out=True))):
            if str(old.get("display_name", "")).startswith(("Doomed ", "Gone While Away", "Kept ")):
                mac.cmux("chief", "delete", old["id"], check=False)
        run_id = time.strftime("%H%M")
        names = {"Doomed Chief": f"Doomed {run_id}", "Gone While Away": f"Gone While Away {run_id}",
                 "Kept Chief": f"Kept {run_id}"}
        made = {}
        for role, name in names.items():
            value = mac.cmux("chief", "new", "--name", name, json_out=True) or {}
            made[role] = (value.get("value") or value).get("id")
        result["names"] = names
        log(f"made Chiefs: {made}")
        result["chiefs"] = made

        j = Journey(sim, mac, out, a.app, log)
        steps = j.run(only={"fresh_install", "sign_in", "choose_space", "mac_discovered"})
        if any(st["status"] != "pass" for st in steps):
            log("setup failed once; relaunching and retrying choose_space")
            sim.launch(journey.BUNDLE)
            steps = j.run(only={"choose_space", "mac_discovered"})[-2:]
        log(f"setup: {[(s['id'], s['status']) for s in steps]}")
        if any(st["status"] != "pass" for st in steps):
            raise RuntimeError(f"setup failed: {steps}")

        # The Mac shows its Home (its list is what the phone mirrors) for its stills and recording.
        result["mac_home_shown"] = debug(mac, "action.run", {"action": "home.show", "origin": "script"}).get("ok")
        path = os.path.join(out, "phone.mp4")
        rec = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", path],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(1.5)
        j.tab("Home")
        ok, secs = wait_for(lambda: shows(sim, names["Doomed Chief"]) and shows(sim, names["Gone While Away"]), 90)
        c["phone_lists_both_before"] = ok
        log(f"phone rows before: {phone_titles(sim)}")
        result["shots"]["phone-before"] = sim.shot("01-phone-before")
        result["shots"]["mac-before"] = mac_shot(mac, os.path.join(shots, "01-mac-before.png"))

        # 1. Online: the Mac's own Delete Chief action, the phone untouched. The Mac window is
        # recorded too (debug.window_record: its own composited frames, at most 12 s).
        mac_rec = os.path.join(out, "mac-frames")
        result["mac_record"] = debug(mac, "debug.window_record", {"dir": mac_rec, "seconds": 10})
        time.sleep(1.5)
        t0 = time.time()
        run = debug(mac, "action.run", {"action": "home.deleteChief", "origin": "script",
                                        "args": {"chief": made["Doomed Chief"], "confirm": True}})
        log(f"Mac Delete Chief (online): {json.dumps(run)[:400]}")
        c["mac_delete_online_ok"] = run.get("ok") is True
        ok, _ = wait_for(lambda: shows(sim, names["Doomed Chief"]) is False, 30)
        result["timings"]["online_row_gone_s"] = round(time.time() - t0, 1) if ok else None
        ok = ok and gone(sim, names["Doomed Chief"])
        c["online_row_left_phone"] = ok
        c["kept_chief_still_listed"], _ = wait_for(lambda: shows(sim, names["Kept Chief"]) is True, 10)
        log(f"phone rows after online delete: {phone_titles(sim)}")
        result["shots"]["phone-after-online"] = sim.shot("02-phone-after-online-delete")
        result["shots"]["mac-after-online"] = mac_shot(mac, os.path.join(shots, "02-mac-after-online-delete.png"))

        # 2. Offline: the phone app is not running while the Mac deletes.
        subprocess.run(["xcrun", "simctl", "terminate", udid, journey.BUNDLE], capture_output=True)
        time.sleep(2)
        run = debug(mac, "action.run", {"action": "home.deleteChief", "origin": "script",
                                        "args": {"chief": made["Gone While Away"], "confirm": True}})
        log(f"Mac Delete Chief (phone offline): {json.dumps(run)[:400]}")
        c["mac_delete_offline_ok"] = run.get("ok") is True
        result["shots"]["mac-after-offline"] = mac_shot(mac, os.path.join(shots, "03-mac-after-offline-delete.png"))
        sim.launch(journey.BUNDLE)
        time.sleep(3)
        j.tab("Home")
        ok, _ = wait_for(lambda: shows(sim, names["Kept Chief"]), 90)
        c["phone_reconnected"] = ok
        # Watch a while: the row must never come back.
        seen = False
        deadline = time.time() + 15
        while time.time() < deadline:
            seen = seen or bool(shows(sim, names["Gone While Away"])) or bool(shows(sim, names["Doomed Chief"]))
            time.sleep(0.5)
        c["offline_row_never_shown"] = not seen
        log(f"phone rows after reopening: {phone_titles(sim)}")
        result["shots"]["phone-after-offline"] = sim.shot("03-phone-after-reopen")
        result["pass"] = all(c.get(k) for k in ("phone_lists_both_before", "mac_delete_online_ok", "online_row_left_phone",
                                                  "kept_chief_still_listed", "mac_delete_offline_ok", "phone_reconnected",
                                                  "offline_row_never_shown"))
        log(f"checks: {json.dumps(c)}")
        log("PASS" if result["pass"] else "FAIL")
    finally:
        if rec:
            rec.send_signal(signal.SIGINT)
            try:
                rec.wait(20)
            except subprocess.TimeoutExpired:
                rec.kill()
        try:
            mac.teardown()
        except Exception as e:  # noqa: BLE001
            log(f"teardown: {e}")
        json.dump(result, open(os.path.join(out, "results.json"), "w"), indent=2)
        log(f"wrote {out}/results.json")


if __name__ == "__main__":
    main()
