#!/usr/bin/env python3
"""Fresh-verifier run of the final transports (verify/transport-verify-20261019.md).

One rig Mac app (an UNMODIFIED copy of the fleet build: no Info.plist edit, no
re-sign; every setting goes in through `open --env`) and the Demo build in ONE
headless simulator, both on this Mac. Every phone action is a tap or typed
text in the app's UI: Settings > Transport for the transport and the Developer
toggles, the composer for terminal commands, the address bar for pages.

    python3 -u transport_verify.py --mac-app APP --app CmuxMobileApp.app setup
    python3 -u transport_verify.py ... mode wg-direct|wg-turn|wg-tls|rtc-direct|rtc-turn|rtc-blockudp
    python3 -u transport_verify.py ... switch|kill|roam|loss-wg|loss-rtc
    python3 -u transport_verify.py ... analyze DIR
    python3 -u transport_verify.py ... teardown

State between invocations: <out>/state.json (sim udid, device id, seed).
"""
import argparse
import datetime
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
CNX = os.path.abspath(os.path.join(HERE, "../.."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(CNX, "verify/scripts"))
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

import importlib.util  # noqa: E402
from e2e import ensure_sim, RUNTIMES  # noqa: E402
from journey import Journey, BUNDLE, _InTerminal  # noqa: E402
from latency import Latency  # noqa: E402
from mac import Mac, TERMINATE_SWIFT, dev_credential  # noqa: E402
from sim import Sim  # noqa: E402

_spec = importlib.util.spec_from_file_location("btb", os.path.join(CNX, "verify/scripts/browser-track-bench.py"))
btb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(btb)

SIM_NAME = "cmux-mobile-tv-ios26"
PORT = 8791
BENCH_URL = f"http://127.0.0.1:{PORT}/s6.html"  # a redirect to bench.html?scroll=6 (no "=" to type)

MODES = {
    # name: (transport, relay only, block UDP, predicate on the link line)
    "wg-direct": ("WireGuard", "0", "0", lambda l: "WireGuard direct" in l),
    "wg-turn": ("WireGuard", "1", "0", lambda l: "WireGuard relay (TURN)" in l),
    "wg-tls": ("WireGuard", "0", "1", lambda l: "TURN over TLS" in l),
    "rtc-direct": ("WebRTC", "0", "0", lambda l: "WebRTC" in l and "TURN" not in l),
    "rtc-turn": ("WebRTC", "1", "0", lambda l: "WebRTC" in l and "TURN" in l),
    "rtc-blockudp": ("WebRTC", "0", "1", lambda l: "WebRTC" in l),
}


class RigMac(Mac):
    """The rig Mac with no bundle edits: settings through `open --env` only."""

    def prepare(self):
        os.makedirs(os.path.join(self.rig, "mac"), exist_ok=True)
        os.makedirs(os.path.dirname(self.config), exist_ok=True)
        os.makedirs(os.path.dirname(self.creds), mode=0o700, exist_ok=True)
        os.chmod(os.path.dirname(self.creds), 0o700)
        if not os.path.isdir(self.app):
            subprocess.run(["ditto", self.source_app, self.app], check=True)
            subprocess.run(["xattr", "-dr", "com.apple.quarantine", self.app], capture_output=True)
        cfg = {}
        if os.path.exists(self.config):
            try:
                cfg = json.load(open(self.config))
            except ValueError:
                cfg = {}
        cfg.setdefault("mobile", {})["allowIPhoneConnections"] = True
        json.dump(cfg, open(self.config, "w"), indent=2)
        if not os.path.exists(self.pairing_seed):
            self.seed_pairing()
        email, password = dev_credential()
        fd = os.open(self.creds, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(f"CMUX_UITEST_STACK_EMAIL={email}\nCMUX_UITEST_STACK_PASSWORD={password}\n")
        bin_dir = os.path.join(self.rig, "bin")
        os.makedirs(bin_dir, exist_ok=True)
        term = os.path.join(bin_dir, "terminate-pid")
        if not os.path.exists(term):
            src = os.path.join(bin_dir, "terminate-pid.swift")
            open(src, "w").write(TERMINATE_SWIFT)
            subprocess.run(["xcrun", "swiftc", "-O", "-o", term, src], check=True, capture_output=True)
        res = os.path.join(self.app, "Contents/Resources")
        self.launch_env = {
            "CMUX_NEXT_CONFIG_FILE": self.config,
            "CMUX_AUTH_CREDENTIALS_FILE": self.creds,
            "CMUX_NEXT_IPHONE_PAIRING_SEED": self.pairing_seed,
            "CMUX_SHELL_INTEGRATION_DIR": f"{res}/shell-integration",
            "CMUX_BUNDLED_CLI_PATH": f"{res}/bin/cmux",
        }
        return self


def load():
    return {"mini_load": [round(x, 1) for x in os.getloadavg()]}


class TV:
    def __init__(self, a):
        self.a = a
        self.out = a.out
        os.makedirs(self.out, exist_ok=True)
        self.logf = open(os.path.join(self.out, "run.log"), "a")
        self.state_path = os.path.join(self.out, "state.json")
        self.state = json.load(open(self.state_path)) if os.path.exists(self.state_path) else {}
        rig = os.path.expanduser(f"~/cmux-next-ios-e2e/tv-{os.path.basename(a.mac_app)[len('cmux DEV '):-4]}")
        self.mac = RigMac(rig, a.mac_app).prepare()
        self.sim = None
        self.j = None
        self.results_path = os.path.join(self.out, "results.json")
        self.results = json.load(open(self.results_path)) if os.path.exists(self.results_path) else {}

    def log(self, msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        self.logf.write(line + "\n")
        self.logf.flush()

    def save(self):
        json.dump(self.state, open(self.state_path, "w"), indent=2)
        json.dump(self.results, open(self.results_path, "w"), indent=2, default=str)

    # ---------------------------------------------------------------- rig
    def up(self):
        if not self.mac.main_pids():
            self.mac.launch()
        else:
            self.mac.pid = self.mac.main_pids()[0]
        self.mac.wait_hostd(120)
        udid = self.state.get("udid") or ensure_sim(SIM_NAME, RUNTIMES["26"], self.log)
        self.state["udid"] = udid
        self.sim = Sim(udid, os.path.join(self.out, "shots"))
        self.j = Journey(self.sim, self.mac, self.out, self.a.app, self.log)
        if self.state.get("seed"):
            self.j.seed = self.state["seed"]
            self.j.ws_name = self.state["ws_name"]
            self.j.device_id = self.state["device_id"]
        self.ensure_server()
        self.patch_journey()

    def patch_journey(self):
        j, sim, mac = self.j, self.sim, self.mac
        original = j.back_to_list

        def to_list():
            """Back buttons first (the journey's own back_to_list can pick a hidden
            sheet's off-screen Done on this app version), then the journey's."""
            for _ in range(6):
                els = sim.tree()
                if any(e.ident == "workspaces.list" for e in els) and any(
                        e.label == "Workspaces" and e.kind == "RadioButton" for e in els):
                    return
                cancel = [e for e in sim.find(kind="Button", elements=els) if e.label == "Cancel"
                          and 0 <= e.frame[0] and 0 <= e.center[1] <= 874]
                if cancel:  # a browser address field holds the keyboard
                    sim.tap_el(cancel[0]); time.sleep(1.0); continue
                if sim.keyboard(els):
                    j.hide_keyboard()
                back = [e for e in sim.find(kind="Button", elements=els)
                        if (e.ident in ("chevron.left", "BackButton") or e.label == "Back") and 0 <= e.center[1] <= 874
                        and e.frame[0] >= 0]
                if back:
                    sim.tap_el(back[0])
                else:
                    try:
                        j.tab("Workspaces")
                    except Exception:
                        sim.drag(2, 400, 320, 400, 0.5, 30, 0.1)
                time.sleep(1.0)
            original()

        j.back_to_list = to_list

        # The ids `workspace create` returned did not resolve later on this build
        # (selector.not_found); resolve terminals from the live list instead.
        def terminals():
            return [t["id"] for t in (mac.cmux("terminal", "list", json_out=True) or [])]

        def which_term(marker):
            for t in terminals():
                try:
                    if marker in j.mac_screen(t).get("text", ""):
                        return t
                except Exception:
                    pass
            return None

        j.which_term = which_term
        ts = terminals()
        if ts:
            j.seed["term1"] = ts[0]
            j.seed["term2"] = ts[-1]

    def ensure_server(self):
        r = subprocess.run(["curl", "-fsS", "-o", "/dev/null", f"http://127.0.0.1:{PORT}/bench.html"], capture_output=True)
        if r.returncode == 0:
            return
        subprocess.Popen([sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1"],
                         cwd=os.path.join(CNX, "verify/scripts/bench-page"), stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True)
        time.sleep(1)

    def setup(self, resume=False):
        self.up()
        env = subprocess.run(["ps", "eww", "-p", str(self.mac.pid)], capture_output=True, text=True).stdout
        seen = {k: (k + "=" + v) in env for k, v in self.mac.launch_env.items()}
        self.log(f"Mac app pid {self.mac.pid}; open --env reached the process: {seen}")
        self.mac.seed_pairing(names=[SIM_NAME])
        seed = self.j.seed_mac()
        self.state.update(seed=seed, ws_name=self.j.ws_name, device_id=self.j.device_id)
        self.save()
        self.log(f"seed {seed}, Mac device {self.j.device_id}")
        steps = {"choose_space", "mac_discovered"} if resume else {"fresh_install", "sign_in", "choose_space", "mac_discovered"}
        res = self.j.run(only=steps)
        self.log(f"setup steps: {[(r['id'], r['status'], (r.get('notes') or '')[:160]) for r in res]}")
        self.results["setup"] = {"steps": res, "open_env": seen, **load()}
        self.save()

    def teardown(self):
        self.log(f"quit Mac: {self.mac.quit()}")
        udid = self.state.get("udid")
        if udid:
            subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", udid], capture_output=True)
        subprocess.run(["pkill", "-f", f"http.server {PORT}"], capture_output=True)
        self.log("teardown done")

    # ---------------------------------------------------------------- helpers
    def hostd_log(self):
        return os.path.join(self.mac.hostd_state, "cmux-mobile-host.log")

    def hostd_lines(self, since_ts, pattern):
        out = []
        p = self.hostd_log()
        if not os.path.exists(p):
            return out
        for line in open(p, errors="replace"):
            m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z", line)
            if not m:
                continue
            ts = datetime.datetime.strptime(m.group(1)[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(
                tzinfo=datetime.timezone.utc).timestamp()
            if ts >= since_ts and re.search(pattern, line):
                out.append(line.rstrip()[:400])
        return out

    def phone_log(self, since, pattern):
        r = subprocess.run(["xcrun", "simctl", "spawn", self.sim.udid, "log", "show", "--style", "compact", "--start", since,
                            "--predicate", 'subsystem BEGINSWITH "dev.cmux"'], capture_output=True, text=True, timeout=300)
        return [l[:400] for l in r.stdout.splitlines() if re.search(pattern, l)]

    def set_mode(self, name):
        transport, relay, block, want = MODES[name]
        j = self.j
        t0 = time.time()
        j.back_to_list()
        b1 = j.relay_toggle(relay, "settings.transport.relayOnly")
        b2 = j.relay_toggle(block, "settings.transport.blockUDP")
        # Transport: tap it on the Transport page (no-op when already chosen).
        j.open_transport_page()
        kind = {"WebRTC": "webrtc", "WireGuard": "wireguard"}[transport]
        self.sim.tap_el(self.sim.find(ident=f"settings.transport.{kind}")[0])
        time.sleep(0.5)
        j.close_transport_page()
        st, dt, seen = j.wait_status(want, timeout=60)
        return {"toggles": {"relayOnly": b1, "blockUDP": b2}, "status": st, "connect_s": round(dt, 1),
                "status_sequence": seen[:8], "t0": t0}

    def rtt_samples(self, n=10, every=2.0):
        vals, lines = [], []
        for _ in range(n):
            lab = self.j.link_status()
            lines.append(lab)
            m = re.search(r"(\d+)\s*ms", lab or "")
            if m:
                vals.append(int(m.group(1)))
            time.sleep(every)
        return {"samples": vals, "median": sorted(vals)[len(vals) // 2] if vals else None,
                "min": min(vals) if vals else None, "max": max(vals) if vals else None, "last_line": lines[-1] if lines else None}

    def composer_send(self, text):
        self.sim.tap_q(ident="terminal.composer.field")
        time.sleep(0.6)
        self.sim.dismiss_keyboard_intro()
        self.sim.softtype(text)
        t = time.time()
        self.sim.tap_q(ident="terminal.composer.send")
        return t

    def terminal_check(self, d):
        """Echo, streaming output, scrollback; all typed on the phone, recorded."""
        j, sim = self.j, self.sim
        res = {}
        j.open_seed_workspace()
        vid = os.path.join(d, "terminal.mp4")
        sim.record_start(vid)
        try:
            term = j.current_tab_marker()
            res["echo_reached_mac"] = term is not None
            term = term or j.seed["term1"]
            tag = f"x{random.randint(1000, 9999)}"
            # Codex-like stream: 400 lines at about 100 lines/s, typed on the soft keyboard.
            cmd = f"for i in $(seq 400);do echo {tag}-$i tok tok;sleep .01;done;echo {tag}-END"
            t = self.composer_send(cmd)
            time.sleep(1.0)
            j.hide_keyboard()
            try:
                j.mac_wait_text(term, f"{tag}-END", timeout=60)
                res["stream_done_on_mac_s"] = round(time.time() - t, 1)
            except Exception as e:
                res["stream_done_on_mac_s"] = None
                res["stream_error"] = str(e)[:200]
            hit = sim.ocr_find(f"{tag}-END", timeout=20)
            res["stream_end_on_phone"] = bool(hit)
            res["stream_end_on_phone_s"] = round(time.time() - t, 1) if hit else None
            sim.shot(os.path.basename(d) + "-stream-end")
            hits, flicks = [], 0
            for flicks in range(45):  # slow pulls, about a screen each
                hits = sim.ocr_find(f"{tag}-200 tok", timeout=0.8)
                if hits:
                    break
                sim.drag(201, 180, 201, 700, duration=0.5, hold=0.3)
                time.sleep(0.5)
            res["scrollback_reached_line_200"] = bool(hits)
            res["scrollback_flicks"] = flicks
            sim.shot(os.path.basename(d) + "-scrollback")
            # Back to the bottom.
            jump = sim.find(label="Scroll to bottom")
            if jump:
                sim.tap_el(jump[0]); time.sleep(1.0)
        finally:
            sim.record_stop()
        res["video"] = vid
        stay = _InTerminal(j)
        lat = Latency(stay, d, self.log, 12)
        try:
            try:
                lat.keystroke_echo(False)
            except IndexError:  # the soft keyboard did not come up (loaded host): once more
                j.hide_keyboard()
                lat.keystroke_echo(False)
            res["keystroke_echo"] = lat.metrics.get("keystroke_echo_idle", {})
            res["keystroke_echo"]["video"] = os.path.join(d, "keystroke_echo_idle.mp4")
        except Exception as e:
            res["keystroke_echo_error"] = str(e)[:300]
        return res

    def meter(self):
        """The measurement overlay's text (OCR; its AX label is empty)."""
        lines = [o[4] for o in self.sim.ocr()]
        return " | ".join(l for l in lines if re.search(r"fps|latency|^phone", l))

    def toolbar_button(self, *names):
        for e in self.sim.find(kind="Button"):
            if (e.label in names or (e.ident or "") in names) and e.frame[0] >= 0 and 0 <= e.center[1] <= 874:
                return e
        return None

    def open_browser(self, url):
        """Hold New Workspace > New Browser Workspace, type the URL in its address bar."""
        j, sim = self.j, self.sim
        j.back_to_list()
        new = sim.wait(ident="workspaces.new", timeout=10)
        if not new:
            raise RuntimeError("no New Workspace button")
        item = None
        for _ in range(3):
            sim.long_press(*new.center, seconds=1.2)
            item = sim.wait(contains="Browser", timeout=4)
            if item:
                item = [item]
                break
            sim.tap(60, 450); time.sleep(0.8)
        if not item:
            raise RuntimeError("no browser workspace in the hold menu")
        t = sim.tap_el(item[0])
        bar = sim.wait(contains="Search or enter website", timeout=20)
        if not bar:
            raise RuntimeError("no address bar in 20 s")
        self.type_url(url, bar)
        return t

    def type_url(self, url, bar=None):
        sim = self.sim
        if bar is None:
            bar = sim.find(contains="Search or enter website") or sim.find(kind="TextField")
            bar = bar[0] if bar else None
        if bar is None:
            # The address pill: tap it to edit.
            cands = [e for e in sim.find(kind="Button") if (e.label or "").startswith("Address")
                     and 0 <= e.center[1] <= 874]
            if not cands:
                raise RuntimeError("no address bar or pill")
            bar = cands[0]
        sim.tap_el(bar)
        time.sleep(0.8)
        sim.dismiss_keyboard_intro()
        clear = [e for e in sim.find(kind="Button") if e.label == "Clear text" and 0 <= e.center[1] <= 874]
        if clear:  # the field shows the current address: clear it first
            sim.tap_el(clear[0]); time.sleep(0.4)
        sim.softtype(url + "\n")

    def wait_page(self, needle_re, timeout=40):
        t = time.time()
        text = ""
        while time.time() - t < timeout:
            text = " ".join(o[4] for o in self.sim.ocr())
            if re.search(needle_re, text):
                return time.time() - t, text
            time.sleep(1.0)
        return None, text

    def browser_check(self, d, carrier_expected):
        """Load the bench page from the phone, scroll, tap, navigate, back, forward; recorded."""
        sim = self.sim
        res = {}
        vid = os.path.join(d, "browser-ui.mp4")
        sim.record_start(vid)
        try:
            t = self.open_browser(BENCH_URL)
            dt, text = self.wait_page(r"mac\s+" + btb.CLOCK, 45)
            res["bench_loaded_s"] = round(time.time() - t, 1) if dt is not None else None
            time.sleep(2)
            res["meter_after_load"] = self.meter()
            # Scroll by touch, then a tap the page counts.
            sim.swipe(200, 620, 200, 320, duration=0.35); time.sleep(1.0)
            sim.swipe(200, 320, 200, 620, duration=0.35); time.sleep(1.0)
            before = re.search(r"taps\s+(\d+)", " ".join(o[4] for o in sim.ocr()))
            sim.tap(200, 520); time.sleep(1.5)
            after = re.search(r"taps\s+(\d+)", " ".join(o[4] for o in sim.ocr()))
            res["tap_counted"] = bool(after) and (not before or int(after.group(1)) > int(before.group(1)))
            res["taps_before_after"] = [before.group(1) if before else None, after.group(1) if after else None]
            # Navigate to another page from the address bar.
            self.type_url("example.com")
            dt2, _ = self.wait_page(r"documentation|Example Domain", 40)
            res["navigate_example_s"] = round(dt2, 1) if dt2 is not None else None
            sim.shot(os.path.basename(d) + "-example")
            back = self.toolbar_button("Back", "BackButton", "Go Back")
            res["back_button"] = back.label if back else None
            if back:
                sim.tap_el(back); dt3, _ = self.wait_page(r"mac\s+" + btb.CLOCK, 30)
                res["back_to_bench_s"] = round(dt3, 1) if dt3 is not None else None
            fwd = self.toolbar_button("Forward", "Go Forward")
            if not fwd:
                # Forward lives with the address field's editing controls.
                pill = [e for e in sim.find(kind="Button") if (e.label or "").startswith("Address") and 0 <= e.center[1] <= 874]
                if pill:
                    sim.tap_el(pill[0]); time.sleep(1.0)
                    fwd = self.toolbar_button("Forward", "Go Forward")
                    res["forward_via"] = "address field editing bar"
            res["forward_button"] = fwd.label if fwd else None
            if fwd:
                sim.tap_el(fwd); dt4, _ = self.wait_page(r"documentation|Example Domain", 30)
                res["forward_to_example_s"] = round(dt4, 1) if dt4 is not None else None
                back = self.toolbar_button("Back", "BackButton", "Go Back")
                if back:
                    sim.tap_el(back); self.wait_page(r"mac\s+" + btb.CLOCK, 30)
            if not back or not fwd:
                res["toolbar_buttons"] = [(e.label, e.ident, [int(x) for x in e.frame]) for e in sim.find(kind="Button")][:40]
            time.sleep(2)
            res["meter_end"] = self.meter()
        finally:
            sim.record_stop()
        res["video"] = vid
        m = (res.get("meter_end") or "") + " " + (res.get("meter_after_load") or "")
        res["carrier_seen"] = next((c for c in ("wg-rtp", "track", "channel") if re.search(rf"\b{c}\b", m)), None)
        res["carrier_ok"] = res["carrier_seen"] == carrier_expected
        return res

    def bench_record(self, d, seconds=12, taps=10):
        """Glass-to-glass, fps and tap-to-frame from a recording of the bench page."""
        sim = self.sim
        os.makedirs(d, exist_ok=True)
        video = os.path.join(d, "screen.mp4")
        sim.record_start(video)
        rec_t0 = time.time()
        time.sleep(seconds)
        tap_ts = []
        for _ in range(taps):
            tap_ts.append(time.time())
            sim.tap(200, 520)
            time.sleep(1.3)
        time.sleep(1.5)
        sim.record_stop()
        cap = {"recording_started_host": rec_t0, "taps_host": tap_ts, "meter": self.meter(),
               "link_status": None, **load()}
        json.dump(cap, open(os.path.join(d, "capture.json"), "w"), indent=2)
        return cap

    def close_browser_workspaces(self):
        for w in self.mac.cmux("workspace", "list", json_out=True) or []:
            if w.get("id") != self.j.seed.get("ws") and "e2e" not in (w.get("title") or w.get("name") or ""):
                self.mac.cmux("workspace", w["id"], "close", check=False)

    # ---------------------------------------------------------------- checks
    def mode(self, name):
        name, _, only = name.partition(":")
        self.up()
        d = os.path.join(self.out, name)
        os.makedirs(d, exist_ok=True)
        prev = self.results.get(name, {})
        r = {"mode": name, "start": datetime.datetime.now().isoformat(timespec="seconds"), **load()}
        since = time.time()
        r.update(self.set_mode(name))
        self.sim.shot(f"{name}-status")
        # Our phone's own link only: other phones on the dev account dial this Mac too.
        mine = self.state.get("phone_id")
        lines = self.hostd_lines(since - 2, r"link up|link path changed")
        if not mine:
            ups = [l for l in lines if "link up" in l and "phone=" in l]
            mine = re.search(r'phone="([^"]+)"', ups[-1]).group(1) if ups else None
        sessions = {m.group(1) for l in lines if mine and mine in l for m in [re.search(r'session_id="([^"]+)"', l)] if m}
        own = [l for l in lines if any(sid in l for sid in sessions)]
        m = re.search(r"path=(\w+)", own[-1]) if own else None
        r["mac_path"] = m.group(1) if m else None
        r["phone_id"] = mine
        r["mac_path_lines"] = own[-4:]
        r["rtt_ms"] = self.rtt_samples()
        self.log(f"{name}: status {r['status']!r} in {r['connect_s']} s, Mac path {r['mac_path']}, rtt {r['rtt_ms']['median']}")
        if only == "browser" and "terminal" in prev:
            r["terminal"] = prev["terminal"]
        else:
            try:
                r["terminal"] = self.terminal_check(d)
            except Exception as e:
                r["terminal_error"] = str(e)[:400]
        self.log(f"{name}: terminal {json.dumps({k: v for k, v in (r.get('terminal') or {}).items() if k != 'keystroke_echo'})[:400]}")
        carrier = "wg-rtp" if name.startswith("wg") else "track"
        try:
            r["browser"] = self.browser_check(d, carrier)
            self.bench_record(os.path.join(d, "bench"))
        except Exception as e:
            r["browser_error"] = str(e)[:400]
            self.sim.shot(f"{name}-browser-error")
        self.log(f"{name}: browser {json.dumps({k: v for k, v in (r.get('browser') or {}).items() if k != 'toolbar_buttons'})[:500]}")
        r["mac_paths_during"] = self.hostd_lines(since, r"link up|link down|link path changed|media lane|video")[-20:]
        lines = self.phone_log(datetime.datetime.fromtimestamp(since).strftime("%Y-%m-%d %H:%M:%S"),
                               r"relay_retired|fps .* via ")
        r["phone_relay_retired"] = [l for l in lines if "relay_retired" in l]
        r["phone_browser"] = [l for l in lines if " via " in l][-12:]
        r["end"] = datetime.datetime.now().isoformat(timespec="seconds")
        r["end_load"] = load()
        try:
            self.j.back_to_list()
            self.close_browser_workspaces()
        except Exception as e:
            r["cleanup_error"] = str(e)[:200]
        self.results[name] = r
        self.save()

    def stream_watch(self, d, label, seconds=25):
        """Records the browser screen; returns the meter's labels over time."""
        seen = []
        t = time.time()
        while time.time() - t < seconds:
            seen.append((round(time.time() - t, 1), self.meter()))
            time.sleep(1.0)
        return seen

    def transition(self, kind):
        """switch: change transport while a tab streams; kill: SIGKILL cmux-mobile-host; roam: the
        DEBUG network probe on WireGuard (relaunch with CMUX_MOBILE_NETWORK_PROBE=roam)."""
        self.up()
        d = os.path.join(self.out, f"t-{kind}")
        os.makedirs(d, exist_ok=True)
        r = {"transition": kind, "start": datetime.datetime.now().isoformat(timespec="seconds"), **load()}
        sim, j = self.sim, self.j
        start_mode = {"switch": "rtc-direct", "kill": "wg-direct", "roam": "wg-direct"}[kind]
        if kind == "roam":
            r.update(self.set_mode("wg-direct"))
            since_s = time.strftime("%Y-%m-%d %H:%M:%S")
            sim.launch(BUNDLE, env={"CMUX_MOBILE_NETWORK_PROBE": "roam", "CMUX_MOBILE_NETWORK_PROBE_DELAY": "40"})
            time.sleep(3)
        else:
            r.update(self.set_mode(start_mode))
            since_s = time.strftime("%Y-%m-%d %H:%M:%S")
        since = time.time()
        vid = os.path.join(d, "transition.mp4")
        self.open_browser(BENCH_URL)
        self.wait_page(r"mac\s+" + btb.CLOCK, 45)
        if kind == "kill":
            # The terminal first: a marker before, then again after.
            pass
        sim.record_start(vid)
        rec_t0 = time.time()
        time.sleep(4)
        r["meter_before"] = self.meter()
        self._recording = True
        ev_t = None
        if kind == "switch":
            # Inside a workspace the tab bar is hidden: the person goes Back to the
            # list, Settings > Transport, taps WireGuard, then reopens the tab.
            ev_t = time.time()
            j.back_to_list()
            j.tab("Settings")
            j.open_transport_page()
            sim.tap_el(sim.find(ident="settings.transport.wireguard")[0])
            time.sleep(0.5)
            j.close_transport_page()
            j.tab("Workspaces")
            time.sleep(1.0)
            rows = [e for e in sim.find(kind="Button") if (e.ident or "").startswith("workspace.row")
                    and not (e.label or "").startswith("e2e-") and 0 <= e.center[1] <= 874]
            r["browser_row"] = rows[0].label if rows else None
            if rows:
                sim.tap_el(rows[0])
            r["switched_at_s"] = round(time.time() - rec_t0, 2)
        elif kind == "kill":
            pids = self.mac.hostd_pids()
            ev_t = time.time()
            for p in pids:
                os.kill(p, signal.SIGKILL)
            r["killed_hostd"] = pids
        elif kind == "roam":
            # The probe fires CMUX_MOBILE_NETWORK_PROBE_DELAY s after the first link up.
            ev_t = None
        try:
            seen = self.stream_watch(d, kind, seconds=45 if kind == "roam" else 30)
        finally:
            sim.record_stop()
        r["video"] = vid
        r["recording_started_host"] = rec_t0
        r["event_at_s"] = round(ev_t - rec_t0, 2) if ev_t else None
        r["meter_timeline"] = seen
        r["meter_end"] = self.meter()
        r["status_end"] = j.link_status() if sim.find(ident="workspaces.list") else None
        r["hostd"] = self.hostd_lines(since - 2, r"link up|link down|link path changed|media lane|video|roam")[-40:]
        r["phone"] = self.phone_log(since_s, r"network_probe|roam|fps .* via |link (up|down)|relay_retired|network changed")[-80:]
        # Terminal still correct afterwards.
        try:
            j.back_to_list()
            j.open_seed_workspace()
            r["terminal_after"] = j.current_tab_marker() is not None
            j.back_to_list()
        except Exception as e:
            r["terminal_after_error"] = str(e)[:300]
        try:
            self.close_browser_workspaces()
        except Exception:
            pass
        r["end_load"] = load()
        self.results[f"t-{kind}"] = r
        self.save()
        self.log(f"t-{kind}: meter timeline {seen[:3]} ... {seen[-3:]}; terminal_after {r.get('terminal_after')}")

    def loss(self, which):
        """3 % of video RTP dropped below the NACK responder (hostd's file, read at each new link)."""
        self.up()
        name = f"loss-{which}"
        d = os.path.join(self.out, name)
        os.makedirs(d, exist_ok=True)
        r = {"loss": which, **load()}
        f = os.path.join(self.mac.hostd_state, "video-drop-permille")
        open(f, "w").write("30\n")
        try:
            # A new link reads the file: switch away and back through the UI.
            other = "rtc-direct" if which == "wg" else "wg-direct"
            mode = "wg-direct" if which == "wg" else "rtc-direct"
            self.set_mode(other)
            since = time.time()
            r.update(self.set_mode(mode))
            self.open_browser(BENCH_URL)
            self.wait_page(r"mac\s+" + btb.CLOCK, 45)
            time.sleep(5)
            r["meter_start"] = self.meter()
            r["capture"] = self.bench_record(os.path.join(d, "bench"), seconds=20, taps=6)
            r["meter_end"] = self.meter()
            r["hostd"] = self.hostd_lines(since, r"media lane|link up")[-20:]
        finally:
            os.remove(f)
            try:
                self.j.back_to_list()
                self.close_browser_workspaces()
            except Exception:
                pass
        self.results[name] = r
        self.save()
        self.log(f"{name}: meter {r.get('meter_start')} -> {r.get('meter_end')}")

    def analyze(self, root):
        bench = btb.Bench(types.SimpleNamespace(seconds=12, offset_ms=0.0), self.log)
        out = {}
        for dirpath, _, files in os.walk(root):
            if "capture.json" in files and "screen.mp4" in files:
                cap = json.load(open(os.path.join(dirpath, "capture.json")))
                secs = 20 if "loss" in dirpath else 12
                bench.a.seconds = secs
                res = bench.analyze(os.path.join(dirpath, "screen.mp4"), dirpath, cap["recording_started_host"], cap["taps_host"])
                json.dump(res, open(os.path.join(dirpath, "result.json"), "w"), indent=2)
                out[os.path.relpath(dirpath, root)] = {k: res.get(k) for k in ("carrier_seen", "g2g_ms", "pacing", "input_to_frame_ms",
                                                                               "mac_input_to_frame_ms", "tap_to_mac_ms")}
                self.log(f"{os.path.relpath(dirpath, root)}: {json.dumps(out[os.path.relpath(dirpath, root)])}")
        json.dump(out, open(os.path.join(root, "bench-results.json"), "w"), indent=2)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("cmd")
    ap.add_argument("arg", nargs="?")
    a = ap.parse_args()
    tv = TV(a)
    tv.log(f"== {a.cmd} {a.arg or ''} load {os.getloadavg()}")
    if a.cmd == "setup":
        tv.setup(resume=a.arg == "resume")
    elif a.cmd == "mode":
        tv.mode(a.arg)
    elif a.cmd in ("switch", "kill", "roam"):
        try:
            tv.transition(a.cmd)
        finally:
            if tv.sim:
                tv.sim.record_stop()
            subprocess.run(["pkill", "-f", "simctl io .* recordVideo"], capture_output=True)
    elif a.cmd == "loss":
        try:
            tv.loss(a.arg)
        finally:
            subprocess.run(["pkill", "-f", "simctl io .* recordVideo"], capture_output=True)
    elif a.cmd == "analyze":
        tv.analyze(a.arg or a.out)
    elif a.cmd == "teardown":
        tv.teardown()
    tv.log(f"== {a.cmd} done")


if __name__ == "__main__":
    main()
