#!/usr/bin/env python3
"""Open on iPhone / Mirror from <Mac> on a browser tab, over the real link.

Runs ON a cmux mini: the hidden e2e rig Mac (mac.py: its own bundle id, config and
credentials, launched with `open -g -j`, never activated) and the iOS app in one
headless simulator driven with AXe (accessibility taps on that simulator only).

    python3 native_browser_live.py --mac-app PATH --app PATH [--sim-name cmux-nativebrowser] [--out DIR]

1. The phone opens a browser workspace on the Mac at example.com: the page is the Mac's,
   mirrored as video (no `browser.native` in the tree).
2. Page Menu > Open on iPhone: the same page loads in the phone's own web view
   (`browser.native`), with the Mac button (`browser.mirror`) and the sign-in caveat toast.
3. The address bar navigates the phone's page (iana.org); the Mac's page stays put.
4. The Mac button: back to the mirror, and the Mac's tab now shows iana.org.
5. The Mac's own localhost (a server on 127.0.0.1 of the rig Mac) mirrors; Open on iPhone
   refuses it with "is on <Mac>. It can only be mirrored."
6. On the phone, an unreachable tailnet host shows "This iPhone can't reach", with Try Again
   and Mirror from <Mac>.
7. The app relaunches: the tab is still on the iPhone.
Each step stills the phone (OCR and accessibility checks). The simulator is recorded for the
whole run. Writes DIR/results.json, run.log, shots/, phone.mp4.
"""
import argparse
import datetime
import http.server
import json
import os
import signal
import socketserver
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "e2e"))
from e2e import CNX, RUNTIMES, ensure_sim  # noqa: E402
import journey  # noqa: E402
from journey import Journey  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from sim import Sim  # noqa: E402

LOCAL_PAGE = b"<!doctype html><title>Mac localhost</title><h1 style='font-size:64px'>Served on the Mac's localhost</h1>"


def serve_localhost():
    """A page only the Mac's own loopback answers (127.0.0.1, an ephemeral port)."""
    class Page(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(LOCAL_PAGE)

        def log_message(self, *args):
            pass

    server = socketserver.TCPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def wait_for(pred, timeout, interval=0.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = pred()
        if value:
            return value
        time.sleep(interval)
    return pred()


def main():  # noqa: C901 - one live scenario
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--sim-name", default="cmux-nativebrowser")
    ap.add_argument("--ios", default="26", choices=sorted(RUNTIMES))
    ap.add_argument("--out")
    a = ap.parse_args()

    mac_app = os.path.abspath(a.mac_app)
    journey.BUNDLE = pb(os.path.join(a.app, "Info.plist"), "Print :CFBundleIdentifier")
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "native-browser")
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
    server = serve_localhost()
    port = server.server_address[1]
    result = {"mac_app": os.path.basename(mac_app), "app": a.app, "simulator": f"{a.sim_name} {udid}",
              "localhost_port": port, "checks": {}, "shots": {}, "notes": {}}
    c, notes = result["checks"], result["notes"]
    rec = None

    def native_shown():
        return any(e.ident == "browser.native" for e in sim.tree())

    def mirror_button():
        hit = sim.find(ident="browser.mirror")
        return hit[0] if hit else None

    def page_menu(item):
        """Page Menu, then the item named `item` (prefix match: "Mirror from" names the Mac)."""
        sim.tap_q(label="Page Menu", timeout=15)
        time.sleep(0.8)
        hit = wait_for(lambda: sim.find(prefix=item), 10)
        if not hit:
            raise RuntimeError(f"page menu has no {item!r}: {[e.label for e in sim.tree() if e.kind == 'Button']}")
        return hit[0]

    def address(text):
        bar = wait_for(lambda: sim.find(prefix="Address") or sim.find(prefix="Show toolbar"), 15)
        if not bar:
            raise RuntimeError("no address bar")
        sim.tap_el(bar[0])
        time.sleep(0.6)
        bar = wait_for(lambda: sim.find(prefix="Address"), 5)
        if bar:
            sim.tap_el(bar[0])
            time.sleep(0.4)
        sim.dismiss_keyboard_intro()
        sim.softtype(text + "\n")

    try:
        mac.launch()
        log(f"Mac app up (pid {mac.pid}), host {'running' if mac.wait_hostd(120) else 'NOT running'}; localhost page on port {port}")
        j = Journey(sim, mac, out, a.app, log)
        steps = j.run(only={"fresh_install", "sign_in", "choose_space", "mac_discovered"})
        if any(st["status"] != "pass" for st in steps):
            log("setup failed once; relaunching and retrying choose_space")
            sim.launch(journey.BUNDLE)
            steps = j.run(only={"choose_space", "mac_discovered"})[-2:]
        log(f"setup: {[(s['id'], s['status']) for s in steps]}")
        if any(st["status"] != "pass" for st in steps):
            raise RuntimeError(f"setup failed: {steps}")

        path = os.path.join(out, "phone.mp4")
        rec = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec", "h264", "--force", path],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(1.5)

        # 1. A browser workspace on the Mac, mirrored.
        j.back_to_list()
        new = sim.wait(ident="workspaces.new", timeout=15)
        sim.long_press(*new.center, seconds=1.0)
        time.sleep(1.0)
        sim.tap_el(wait_for(lambda: sim.find(contains="Browser"), 10)[0])
        bar = sim.wait(contains="Search or enter website", timeout=30)
        sim.tap_el(bar)
        time.sleep(0.8)
        sim.dismiss_keyboard_intro()
        sim.softtype("example.com\n")
        c["mirrored_example"] = bool(sim.ocr_find("Example Domain", timeout=45))
        c["mirrored_is_not_native"] = not native_shown() and bool(sim.find(ident="browser.stream"))
        result["shots"]["01-mirrored"] = sim.shot("01-mirrored-example")

        # 2. Open on iPhone.
        item = page_menu("Open on iPhone")
        result["shots"]["02-menu"] = sim.shot("02-page-menu-open-on-iphone")
        sim.tap_el(item)
        c["native_shown"] = bool(wait_for(native_shown, 15))
        c["caveat_toast"] = bool(wait_for(lambda: sim.find(contains="Sign-ins on"), 5))
        c["mirror_button"] = mirror_button() is not None
        c["native_example"] = bool(sim.ocr_find("Example Domain", timeout=30))
        result["shots"]["03-native"] = sim.shot("03-native-example")

        # 3. Browse on the phone: iana.org's reserved domains page.
        address("www.iana.org/domains/reserved")
        c["native_navigated"] = bool(sim.ocr_find("Reserved Domains", timeout=45))
        c["still_native_after_navigation"] = native_shown()
        result["shots"]["04-native-navigated"] = sim.shot("04-native-navigated")

        # 4. The Mac button: back to the mirror, which continues at iana.org.
        sim.tap_el(mirror_button())
        c["back_to_mirror"] = bool(wait_for(lambda: not native_shown() and sim.find(ident="browser.stream"), 15))
        c["mac_followed_phone"] = bool(sim.ocr_find("Reserved Domains", timeout=45))
        result["shots"]["05-mirror-continues"] = sim.shot("05-mirror-continues-at-iana")

        # 5. The Mac's localhost: mirrored fine, refused natively.
        address(f"localhost:{port}")
        c["mirrored_mac_localhost"] = bool(sim.ocr_find("Served on the Mac", timeout=45))
        result["shots"]["06-mirrored-localhost"] = sim.shot("06-mirrored-mac-localhost")
        sim.tap_el(page_menu("Open on iPhone"))
        toast = wait_for(lambda: sim.find(contains="can only be mirrored"), 6)
        c["localhost_refused_with_reason"] = bool(toast)
        notes["localhost_toast"] = toast[0].label if toast else None
        c["localhost_stays_mirrored"] = not native_shown()
        result["shots"]["07-localhost-refused"] = sim.shot("07-localhost-stays-mirrored")

        # 6. On the phone, a tailnet host it can't reach.
        address("example.com")
        sim.ocr_find("Example Domain", timeout=45)
        sim.tap_el(page_menu("Open on iPhone"))
        wait_for(native_shown, 15)
        address("http://no-such-host-cmux.tail137216.ts.net:3000")
        card = wait_for(lambda: sim.find(ident="browser.native.problem"), 45)
        c["unreachable_card"] = bool(card) and bool(sim.find(contains="This iPhone can't reach"))
        c["unreachable_explains_network"] = bool(sim.find(contains="reachable from"))
        c["unreachable_offers_mirror"] = bool(sim.find(ident="browser.native.mirror")) and bool(sim.find(ident="browser.native.retry"))
        result["shots"]["08-unreachable"] = sim.shot("08-unreachable-tailnet-host")
        address("example.com")
        sim.ocr_find("Example Domain", timeout=45)

        # 7. Relaunch: the tab is still on the iPhone.
        subprocess.run(["xcrun", "simctl", "terminate", udid, journey.BUNDLE], capture_output=True)
        time.sleep(2)
        sim.launch(journey.BUNDLE)
        c["native_after_relaunch"] = bool(wait_for(native_shown, 60))
        result["shots"]["09-relaunched"] = sim.shot("09-relaunched-still-native")
        # And back, from the page menu this time.
        sim.tap_el(page_menu("Mirror from"))
        c["menu_mirror_back"] = bool(wait_for(lambda: not native_shown() and sim.find(ident="browser.stream"), 15))
        result["shots"]["10-menu-mirror"] = sim.shot("10-mirror-from-menu")

        result["pass"] = all(c.values())
        log(f"checks: {json.dumps(c)}")
        log("PASS" if result["pass"] else "FAIL")
    finally:
        if rec:
            rec.send_signal(signal.SIGINT)
            try:
                rec.wait(20)
            except subprocess.TimeoutExpired:
                rec.kill()
        server.shutdown()
        try:
            mac.teardown()
        except Exception as e:  # noqa: BLE001
            log(f"teardown: {e}")
        json.dump(result, open(os.path.join(out, "results.json"), "w"), indent=2)
        log(f"wrote {out}/results.json")


if __name__ == "__main__":
    main()
