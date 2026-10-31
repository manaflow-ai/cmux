#!/usr/bin/env python3
"""Redial rows of verify/redial-video.md (transport-verify-20261019.md defects 7
and 2), on the transport_verify.py rig: one unmodified rig Mac app (settings
through `open --env` only) and the Demo build in one headless simulator, both
on this Mac, over the real link (dev Worker signaling, Cloudflare TURN).

    python3 -u redial_video.py --mac-app APP --app CmuxMobileApp.app --out DIR setup
    python3 -u redial_video.py ... browser kill:wg-only|kill:hybrid|kill:rtc-only
    python3 -u redial_video.py ... browser switch:wg-only|switch:hybrid|switch:rtc-only
    python3 -u redial_video.py ... terminal quit|crash|daemon
    python3 -u redial_video.py ... analyze DIR

Browser row: open two browser workspaces from the phone (A, then B, both the
bench page), close A on the Mac, keep B on screen, then kill cmux-mobile-host (`kill`)
or switch the transport in Settings and reopen B (`switch`). The phone's
overlay (carrier, fps) is read for 30 s, then 12 s of the bench page are
recorded for browser-track-bench.py's analysis. `switch:<link>` ends on that
link: wg-only starts on WebRTC with the media session off and switches to
WireGuard; hybrid starts on WebRTC and switches to WireGuard; rtc-only starts
on WireGuard and switches to WebRTC.

Terminal row: the phone shows the seeded terminal; the Mac app quits
gracefully (`quit`) or is killed (`crash`, as the DEBUG watchdog abort did) and
starts again (`daemon`: the app and its daemon are killed, so surfaces are
numbered again); then a command typed on the phone must reach the Mac.
"""
import datetime
import json
import os
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import transport_verify as tv  # noqa: E402
from journey import BUNDLE  # noqa: E402

# Our own simulator (the verifier's rig used cmux-mobile-tv-ios26).
tv.SIM_NAME = "cmux-mobile-redial-ios26"

CARRIER = {"wg-only": "wg-rtp", "hybrid": "track", "rtc-only": "track"}
NO_MEDIA = {"CMUX_MOBILE_DEV_NO_WEBRTC_MEDIA": "1"}


class Redial(tv.TV):
    def relaunch_phone(self, env):
        """The Demo app again with `env` (the media-session switch is read at launch)."""
        self.sim.launch(BUNDLE, env=env)
        time.sleep(4)
        self.state["phone_env"] = env
        self.save()

    def link(self, transport, env):
        # Every row starts from a fresh launch with its environment.
        self.relaunch_phone(env)
        return self.set_mode("wg-direct" if transport == "wireguard" else "rtc-direct")

    def mac_workspaces(self):
        return {w["id"]: (w.get("title") or w.get("name") or "") for w in self.mac.cmux("workspace", "list", json_out=True) or []}

    def browser_row(self, spec):
        kind, _, link = spec.partition(":")
        self.up()
        d = os.path.join(self.out, f"{kind}-{link}")
        os.makedirs(d, exist_ok=True)
        r = {"row": spec, "start": datetime.datetime.now().isoformat(timespec="seconds"), **tv.load()}
        sim, j = self.sim, self.j
        env = NO_MEDIA if link == "wg-only" else {}
        if kind == "kill":
            start = "webrtc" if link == "rtc-only" else "wireguard"
        else:
            start = "wireguard" if link == "rtc-only" else "webrtc"
        r["start_link"] = self.link(start, env)
        # Two browser workspaces from the phone, A then B.
        before = set(self.mac_workspaces())
        self.open_browser(tv.BENCH_URL)
        r["a_loaded_s"] = self.wait_page(r"mac\s+" + tv.btb.CLOCK, 45)[0]
        after_a = self.mac_workspaces()
        a_ids = [w for w in after_a if w not in before]
        j.back_to_list()
        self.open_browser(tv.BENCH_URL)
        r["b_loaded_s"] = self.wait_page(r"mac\s+" + tv.btb.CLOCK, 45)[0]
        # A closes on the Mac; B stays on the phone's screen.
        for ws in a_ids:
            self.mac.cmux("workspace", ws, "close", check=False)
        r["closed_on_mac"] = a_ids
        time.sleep(3)
        since_s = time.strftime("%Y-%m-%d %H:%M:%S")
        since = time.time()
        vid = os.path.join(d, "transition.mp4")
        sim.record_start(vid)
        rec_t0 = time.time()
        time.sleep(4)
        r["meter_before"] = self.meter()
        if kind == "kill":
            pids = self.mac.hostd_pids()
            ev_t = time.time()
            for p in pids:
                os.kill(p, signal.SIGKILL)
            r["killed_hostd"] = pids
        else:
            ev_t = time.time()
            j.back_to_list()
            j.tab("Settings")
            j.open_transport_page()
            target = "webrtc" if link == "rtc-only" else "wireguard"
            sim.tap_el(sim.find(ident=f"settings.transport.{target}")[0])
            time.sleep(0.5)
            j.close_transport_page()
            j.tab("Workspaces")
            time.sleep(1.0)
            rows = [e for e in sim.find(kind="Button") if (e.ident or "").startswith("workspace.row")
                    and not (e.label or "").startswith("e2e-") and 0 <= e.center[1] <= 874]
            r["browser_rows"] = [e.label for e in rows]
            if rows:
                sim.tap_el(rows[0])
                # Leaving the workspace took the toolbar's Back, which walks the
                # page's history first (to the new tab's about:blank): Forward
                # brings the bench page back, from the same Mac host's history.
                time.sleep(2.0)
                fwd = self.toolbar_button("Forward", "Go Forward")
                r["forward_after_reopen"] = bool(fwd)
                if fwd:
                    sim.tap_el(fwd)
        r["event_at_s"] = round(ev_t - rec_t0, 2)
        try:
            r["meter_timeline"] = self.stream_watch(d, kind, seconds=30)
        finally:
            sim.record_stop()
        r["video"] = vid
        r["recording_started_host"] = rec_t0
        r["meter_end"] = self.meter()
        r["bench"] = self.bench_record(os.path.join(d, "bench"), seconds=12, taps=6)
        lines = self.hostd_lines(since, r"browser|link up|link down|media lane|media session|evicted|least recently")
        r["hostd"] = lines[-60:]
        r["browser_opens_after"] = len([line for line in lines if "video on the link's media lane" in line and self.hostd_ts(line) > ev_t])
        r["evictions"] = [line for line in lines if "least recently used" in line]
        r["took_back"] = [line for line in lines if "takes the media lane back" in line]
        r["phone"] = self.phone_log(since_s, r"browser .*(closed|fps .* via )|link (up|down)")[-40:]
        expected = CARRIER[link]
        tail = [m for _, m in r["meter_timeline"][-10:]]
        r["carrier_tail"] = [next((c for c in ("wg-rtp", "track", "channel") if re.search(rf"\b{c}\b", m)), None) for m in tail]
        fps = [int(x) for m in tail for x in re.findall(r"(\d+)\s*fps", m)]
        r["fps_tail"] = fps
        r["carrier_ok"] = bool(r["carrier_tail"]) and all(c == expected for c in r["carrier_tail"])
        try:
            j.back_to_list()
            self.close_browser_workspaces()
        except Exception as e:
            r["cleanup_error"] = str(e)[:200]
        r["end_load"] = tv.load()
        self.results[f"{kind}-{link}"] = r
        self.save()
        self.log(f"{kind}-{link}: carrier tail {r['carrier_tail']} fps {fps} (want {expected}); "
                 f"opens after {r['browser_opens_after']}, evictions {len(r['evictions'])}, took back {len(r['took_back'])}")

    @staticmethod
    def hostd_ts(line):
        m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z", line)
        if not m:
            return 0
        return datetime.datetime.strptime(m.group(1)[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(
            tzinfo=datetime.timezone.utc).timestamp()

    def daemon_pids(self):
        r = subprocess.run(["pgrep", "-f", f"cmux-tui --headless --session cmux-app-{self.mac.tag}"],
                           capture_output=True, text=True)
        return [int(x) for x in r.stdout.split()]

    def surfaces(self):
        return sorted(t.get("id") for t in self.mac.cmux("terminal", "list", json_out=True) or [])

    def terminal_row(self, how):
        self.up()
        d = os.path.join(self.out, f"terminal-{how}")
        os.makedirs(d, exist_ok=True)
        r = {"row": f"terminal {how}", "start": datetime.datetime.now().isoformat(timespec="seconds"), **tv.load()}
        sim, j = self.sim, self.j
        self.relaunch_phone({})
        r["link"] = self.set_mode("wg-direct")
        j.open_seed_workspace()
        r["term_before"] = j.current_tab_marker()
        r["daemon_before"] = self.daemon_pids()
        r["surfaces_before"] = self.surfaces()
        vid = os.path.join(d, "restart.mp4")
        sim.record_start(vid)
        rec_t0 = time.time()
        try:
            time.sleep(3)
            ev_t = time.time()
            if how in ("crash", "daemon"):
                # `daemon`: the app and its cmux-tui daemon die together, so the
                # relaunched app starts a new daemon that restores every
                # workspace with new surface numbers.
                for p in self.mac.main_pids() + (self.daemon_pids() if how == "daemon" else []):
                    os.kill(p, signal.SIGKILL)
                deadline = time.time() + 20
                while time.time() < deadline and (self.mac.main_pids() or self.mac.hostd_pids()):
                    time.sleep(0.3)
            else:
                r["quit"] = self.mac.quit()
            r["down_s"] = round(time.time() - ev_t, 1)
            self.mac.launch()
            self.mac.wait_hostd(120)
            r["up_s"] = round(time.time() - ev_t, 1)
            # The phone stays on the terminal; the link comes back by itself.
            t = time.time()
            reattached = None
            while time.time() - t < 60:
                text = " ".join(o[4] for o in sim.ocr())
                if "Reattaching" not in text and "Connecting" not in text:
                    reattached = round(time.time() - t, 1)
                    break
                time.sleep(1.0)
            r["pill_cleared_s"] = reattached
            sim.shot(f"terminal-{how}-after")
            r["term_after"] = j.current_tab_marker()
            text = " ".join(o[4] for o in sim.ocr())
            r["unknown_surface_on_screen"] = "unknown surface" in text
            r["reattaching_on_screen"] = "Reattaching" in text
            sim.shot(f"terminal-{how}-typed")
        finally:
            sim.record_stop()
        r["video"] = vid
        r["event_at_s"] = round(ev_t - rec_t0, 2)
        r["daemon_after"] = self.daemon_pids()
        r["surfaces_after"] = self.surfaces()
        r["phone"] = self.phone_log(datetime.datetime.fromtimestamp(rec_t0).strftime("%Y-%m-%d %H:%M:%S"),
                                    r"surface .*(reattach|now surface|no longer|attach)|unknown surface|resolve")[-40:]
        r["ok"] = bool(r["term_after"]) and not r["unknown_surface_on_screen"]
        j.back_to_list()
        self.results[f"terminal-{how}"] = r
        self.save()
        self.log(f"terminal-{how}: daemon {r['daemon_before']} -> {r['daemon_after']}; surfaces "
                 f"{r['surfaces_before']} -> {r['surfaces_after']}; typed reached {r['term_after']}; "
                 f"unknown surface on screen {r['unknown_surface_on_screen']}")


def main():
    ap = tv.argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("cmd")
    ap.add_argument("arg", nargs="?")
    a = ap.parse_args()
    rig = Redial(a)
    rig.log(f"== {a.cmd} {a.arg or ''} load {os.getloadavg()}")
    try:
        if a.cmd == "setup":
            rig.setup(resume=a.arg == "resume")
        elif a.cmd == "browser":
            rig.browser_row(a.arg)
        elif a.cmd == "terminal":
            rig.terminal_row(a.arg)
        elif a.cmd == "analyze":
            rig.analyze(a.arg or a.out)
        elif a.cmd == "teardown":
            rig.teardown()
    finally:
        if rig.sim:
            rig.sim.record_stop()
        subprocess.run(["pkill", "-f", "simctl io .* recordVideo"], capture_output=True)
    rig.log(f"== {a.cmd} done")


if __name__ == "__main__":
    main()
