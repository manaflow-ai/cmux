#!/usr/bin/env python3
"""Streamed browser tab: video track vs reliable channel, measured black-box on
the E2E rig (verify/browser-video-track.md "Live verification").

One tagged cmux-next DEBUG Mac app (hidden, isolated, the rig's Mac class) and
the iOS app in ONE headless simulator on this Mac. The Mac's browser tab loads
bench-page/bench.html, which scrolls itself every frame and shows the Mac's
wall clock ("mac MM:SS.mmm") and, on each pointerdown, the time it arrived
("taps N at MM:SS.mmm"). The phone's measurement overlay shows the phone's
clock ("phone MM:SS.mmm") and the carrier ("· track", "· wg-rtp" or
"· channel"). The
simulator and the Mac app share this Mac's clock, so no offset applies.

Per configuration (carrier x path x loss), from the simulator's recording:
- glass to glass: phone clock - page clock in the same video frame (OCR);
- frame pacing: intervals between video frames whose page area changed;
- input to frame: tap sent (host time) -> first video frame showing that tap's
  count (its phone clock), split at the page's own receipt time.

Configurations: `[wg-|hy-]{track,channel}[-relay|-tls][-loss<permille>]`. A
`wg-` prefix dials WireGuard (`-cmuxMobile.settings.transport wireguard`) with no WebRTC
media session beside it (CMUX_MOBILE_DEV_NO_WEBRTC_MEDIA), so its lane is RTP inside the
tunnel (overlay label `wg-rtp`): the "WireGuard only" baseline. `hy-` dials
WireGuard as the app does by default (verify/hybrid-link.md): the link rides
the tunnel and browser video a WebRTC media session's track (`track`), or the
tunnel's RTP when that session fails (`hy-track-tls`, UDP blocked: `wg-rtp`).
Without a prefix the link is WebRTC.
`-relay` is relay only (TURN over UDP); `-tls` (WireGuard only) blocks UDP on
the phone (CMUX_MOBILE_DEV_BLOCK_UDP), so WireGuard rides TURN over TLS on 443. (The
old `-wss` configuration rode the backend's WebSocket relay, which is retired.)

--surface (verify/simulator-surface.md): the bench tab is a Mac phone tab
instead of a browser tab. The rig Mac boots its own headless simulator
(`--rig-sim`, never Simulator.app), opens the bench page in its Safari, and
the workspace `bench` holds one phone tab of that simulator; the phone streams
it with the `surface` service. Glass to glass is then page clock (rendered by
the rig simulator's Safari) to the phone's clock, through the simulator's
framebuffer, VideoToolbox and the same media lane; taps land on the page
through the simulator's HID.

usage: browser-track-bench.py --mac-app APP [--configs track,channel,track-relay,channel-relay,track-loss30,wg-track,wg-channel,wg-track-relay,wg-track-tls,wg-track-loss30]
       [--seconds 12] [--taps 10] [--keep] [--no-build]
"""
import argparse
import datetime
import json
import os
import re
import statistics
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CNX = os.path.abspath(os.path.join(HERE, "../.."))
sys.path.insert(0, os.path.join(CNX, "verify/e2e"))
os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")

import e2e  # noqa: E402
from journey import Journey, BUNDLE  # noqa: E402
from latency import frames as video_frames, diff  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from sim import Sim  # noqa: E402

PORT = 8791
CLOCK = r"(\d{2}):(\d{2})[.,:](\d{3})"


def ms_of(m):
    return (int(m.group(1)) * 60 + int(m.group(2))) * 1000 + int(m.group(3))


def wrap(d):
    d %= 3_600_000
    return d - 3_600_000 if d > 1_800_000 else d


def pct(values, p):
    if not values:
        return None
    v = sorted(values)
    return round(v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))], 1)


def drop_misreads(samples, jump=500):
    """Glass-to-glass samples in frame order without OCR misreads: a sample
    more than `jump` ms above both neighbours is one misread digit of the
    seconds (the 175127 and warm-e 1 to 5 s maxima: "07" read as "09",
    "43" as "48"); a real stall raises a run of frames, not one."""
    kept, dropped = [], 0
    for i, d in enumerate(samples):
        prev = samples[i - 1] if i > 0 else None
        nxt = samples[i + 1] if i + 1 < len(samples) else None
        neighbours = [n for n in (prev, nxt) if n is not None]
        if neighbours and all(d - n > jump for n in neighbours):
            dropped += 1
            continue
        kept.append(d)
    return kept, dropped


def ocr(paths):
    out = {}
    for i in range(0, len(paths), 200):
        r = subprocess.run(["swift", os.path.join(HERE, "ocr-frames.swift"), *paths[i:i + 200]],
                           capture_output=True, text=True, timeout=1200)
        for line in r.stdout.splitlines():
            name, _, text = line.partition("\t")
            out[name] = text
    return out


def extract(video, out_dir, crop_pts, step=1):
    """Every `step`-th video frame, cropped (points), as JPEG; returns [(pts, path)]."""
    os.makedirs(out_dir, exist_ok=True)
    x, y, w, h = [int(v * 3) for v in crop_pts]
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time",
                            "-of", "csv=p=0", video], capture_output=True, text=True)
    times = [float(t.strip(",")) for t in probe.stdout.split() if t.strip(",") not in ("", "N/A")]
    # setpts=N/TB: one JPEG per video frame even where the recording repeats a pts (a
    # stalled stream), so the files stay aligned with ffprobe's frame times.
    subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough",
                    "-vf", f"crop={w}:{h}:{x}:{y},setpts=N/TB", "-q:v", "3", os.path.join(out_dir, "f%05d.jpg")], check=True)
    out = []
    for i, t in enumerate(times):
        p = os.path.join(out_dir, f"f{i + 1:05d}.jpg")
        if os.path.exists(p) and i % step == 0:
            out.append((t, p))
    return out


def daemon_rpc(mac, request):
    """One request on the rig app's own daemon socket (cmux-mobile-host's CMUX_MOBILE_TUI_SOCKET)."""
    import socket as _socket
    pids = mac.hostd_pids()
    env = subprocess.run(["ps", "eww", "-p", str(pids[0])], capture_output=True, text=True).stdout if pids else ""
    m = re.search(r"CMUX_MOBILE_TUI_SOCKET=(\S+)", env)
    if not m:
        raise RuntimeError("no daemon socket (cmux-mobile-host not running)")
    s = _socket.socket(_socket.AF_UNIX)
    s.connect(m.group(1))
    s.sendall((json.dumps(request) + "\n").encode())
    for line in s.makefile():
        reply = json.loads(line)
        if "event" not in reply:
            s.close()
            return reply
    return None


class Bench:
    def __init__(self, a, log):
        self.a, self.log = a, log

    # ---- Mac side ----------------------------------------------------------------
    def mac_env(self, mac, drop_permille):
        """The loss share for cmux-mobile-host: $CMUX_MOBILE_STATE_DIR/video-drop-permille, read at each
        new link (the app hands hostd no other environment). Never Info.plist: a changed
        bundle is a new ad hoc identity, whose Keychain reads then wait on a prompt and
        hostd never starts. Returns False: no restart is needed."""
        path = os.path.join(mac.hostd_state, "video-drop-permille")
        os.makedirs(mac.hostd_state, exist_ok=True)
        if drop_permille:
            with open(path, "w") as f:
                f.write(f"{drop_permille}\n")
        elif os.path.exists(path):
            os.remove(path)
        return False

    def hostd_env(self, mac):
        pids = mac.hostd_pids()
        if not pids:
            return {}
        r = subprocess.run(["ps", "eww", "-p", str(pids[0])], capture_output=True, text=True)
        return dict(re.findall(r"(CMUX_MOBILE_[A-Z_]+)=(\S+)", r.stdout))

    # ---- phone side --------------------------------------------------------------
    def open_bench(self, j, sim):
        if j is not None:
            j.back_to_list()
        else:
            # Remote Mac: dismiss an "offline" note about a cached Mac, then pick
            # the remote Mac in the list's Filter (its device id).
            ok = sim.find(label="OK", kind="Button")
            if ok:
                sim.tap_el(ok[0]); time.sleep(0.8)
            f = sim.wait(ident="workspaces.filter", timeout=15)
            if f:
                sim.press(*f.center, hold=0.1)
                item = sim.wait(ident=f"workspaces.filter.{self.a.mac_device}", timeout=8)
                if item:
                    sim.press(*item.center, hold=0.1)
                    time.sleep(2)
        row = sim.wait(prefix="bench", kind="Button", timeout=60)
        if not row:
            raise RuntimeError("workspace bench not on the phone")
        sim.tap_el(row)
        deadline = time.time() + 40
        while time.time() < deadline:
            text = " ".join(o[4] for o in sim.ocr())
            if re.search(r"fps", text) and re.search(r"mac\s+" + CLOCK, text):
                return text
            time.sleep(1)
        raise RuntimeError("the streamed page never showed (no overlay or page clock)")

    def run_config(self, name, mac, sim, j, out, warmup=0.0):
        hybrid = name.startswith("hy-")
        wg = name.startswith("wg-") or hybrid
        base = name[3:] if wg else name
        tls = "tls" in base
        if base.startswith("channel"):
            carrier = "channel"
        elif hybrid:
            # The media session needs UDP; with it blocked video stays in the tunnel.
            carrier = "wg-rtp" if tls else "track"
        else:
            carrier = "wg-rtp" if wg else "track"
        if "wss" in base:
            raise ValueError(f"{name}: the WebSocket relay is retired; use -tls (TURN over TLS)")
        relay = "relay" in base
        m = re.search(r"loss(\d+)", name)
        drop = int(m.group(1)) if m else 0
        self.log(f"=== {name}: transport {'wireguard' if wg else 'webrtc'}, carrier {carrier}, relay only {relay}"
                 f"{' (UDP blocked: TURN over TLS)' if tls else ''}, drop {drop}/1000")
        args = ["-cmuxMobile.dev.relayOnly", "YES" if relay else "NO",
                "-cmuxMobile.settings.transport", "wireguard" if wg else "webrtc",
                "-cmuxMobile.dev.browserVideoOnChannel", "YES" if carrier == "channel" else "NO"]
        sim_env = {"CMUX_MOBILE_DEV_BLOCK_UDP": "1"} if tls else {}
        if wg and not hybrid:
            sim_env["CMUX_MOBILE_DEV_NO_WEBRTC_MEDIA"] = "1"
        sim_env = sim_env or None
        if self.a.remote:
            # The Mac app runs on a fleet Mac (browser-track-mac.sh); hostd reads the
            # drop share from its state folder at each new link.
            subprocess.run(["ssh", self.a.remote, f"echo {drop} > \"$HOME/Library/Application Support/{self.a.remote_bundle}/cmux-mobile-host/video-drop-permille\""],
                           check=True, timeout=60)
            env = {"CMUX_MOBILE_VIDEO_DROP_PERMILLE(file)": str(drop)}
            args += [f"-cmuxMobile.live.mac.{self.a.team}", self.a.mac_device, "-cmux-mobile-tab", "workspaces"]
        else:
            if self.mac_env(mac, drop) or not mac.main_pids():
                mac.quit()
                mac.launch()
                mac.wait_hostd(120)
                time.sleep(3)
            env = self.hostd_env(mac)
            if drop:
                env["CMUX_MOBILE_VIDEO_DROP_PERMILLE(file)"] = str(drop)
        sim.launch(BUNDLE, args=args, env=sim_env)
        time.sleep(4)
        shown = self.open_bench(j, sim)
        # Wait for the carrier the configuration asks for.
        deadline = time.time() + 20
        while time.time() < deadline and f"· {carrier}" not in shown and f"- {carrier}" not in shown \
                and not re.search(rf"\b{carrier}\b", shown):
            time.sleep(1)
            shown = " ".join(o[4] for o in sim.ocr())
        if warmup:
            # Not measured: the first stream after the browser host starts
            # ran about 25 ms slower glass to glass on whichever carrier came
            # first (175127 wg-track, 162551 track, order-d wg-channel).
            self.log(f"    warm-up: streaming {warmup:.0f} s unmeasured")
            time.sleep(warmup)
            return None
        status = j.link_status() if j is not None else ""
        cfg_dir = os.path.join(out, name)
        # A configuration listed twice keeps both recordings (name-2, ...).
        run = 2
        while os.path.exists(cfg_dir):
            cfg_dir = os.path.join(out, f"{name}-{run}")
            run += 1
        os.makedirs(cfg_dir, exist_ok=True)
        video = os.path.join(cfg_dir, "screen.mp4")
        sim.record_start(video)
        rec_t0 = time.time()
        events = self.media_faults(mac, rec_t0) if (hybrid and mac is not None) else []
        time.sleep(max(0.0, rec_t0 + self.a.seconds - time.time()))
        taps = []
        for _ in range(self.a.taps):
            t = time.time()
            sim.tap(200, 520)
            taps.append(t)
            time.sleep(1.3)
        # --swipes: scroll the streamed page by touch (up, then back down), in the video.
        for i in range(self.a.swipes):
            if i % 2 == 0:
                sim.swipe(200, 620, 200, 320, duration=0.35)
            else:
                sim.swipe(200, 320, 200, 620, duration=0.35)
            time.sleep(1.2)
        time.sleep(1.5)
        sim.record_stop()
        shot = sim.shot(f"{os.path.basename(cfg_dir)}-end")
        result = {"config": os.path.basename(cfg_dir), "transport": "wireguard" if wg else "webrtc",
                  "webrtc_media_session": hybrid, "udp_blocked": tls,
                  "carrier_expected": carrier, "relay_only": relay, "drop_permille": drop,
                  "hostd_env": env, "overlay_at_start": shown[:300], "link_status": status,
                  "recording_started_host": rec_t0, "taps_host": taps, "screenshot": shot,
                  "media_faults": events}
        json.dump(result, open(os.path.join(cfg_dir, "capture.json"), "w"), indent=2)
        if self.a.record_only:
            return result
        result.update(self.analyze(video, cfg_dir, rec_t0, taps))
        json.dump(result, open(os.path.join(cfg_dir, "result.json"), "w"), indent=2)
        self.log(f"    {name}: {json.dumps({k: result.get(k) for k in ('carrier_seen', 'g2g_ms', 'pacing', 'input_to_frame_ms', 'mac_input_to_frame_ms')})}")
        return result

    def media_faults(self, mac, t0):
        """--kill-at / --blackhole-at (hy- configurations): signal cmux-mobile-host mid-recording
        (media_session.rs; hostd honors them only when its state folder holds a
        `test-signals` file at start): SIGUSR2 closes every WebRTC media session (it failed: video
        falls back into the tunnel, the phone dials a new one); SIGUSR1 toggles a black
        hole under the sessions' tracks (a path that died silently: no feedback, so the
        Mac falls back within the stall time and retries after a backoff). Returns the
        signals sent, in seconds since the recording started."""
        plan = []
        if self.a.kill_at is not None:
            plan.append((self.a.kill_at, "USR2", "kill"))
        for at in self.a.blackhole_at or []:
            plan.append((at, "USR1", "blackhole-toggle"))
        events = []
        for at, sig, what in sorted(plan):
            time.sleep(max(0.0, t0 + at - time.time()))
            pids = mac.hostd_pids()
            if pids:
                subprocess.run(["kill", f"-{sig}", str(pids[0])], check=False)
            events.append({"t": round(time.time() - t0, 3), "signal": sig, "what": what, "hostd": pids[:1]})
            self.log(f"    {what} at {events[-1]['t']} s (hostd {pids[:1]})")
        return events

    # ---- analysis ------------------------------------------------------------------
    def analyze(self, video, cfg_dir, rec_t0, taps):
        # Pacing: page area (below the page HUD, above the overlay) frame to frame.
        fr = video_frames(video, (0, 260, 402, 300))
        changes = []
        prev = None
        for t, img in fr:
            if prev is not None and diff(prev, img) > 1.0:
                changes.append(t)
            prev = img
        scroll_end = self.a.seconds - 0.5
        moving = [t for t in changes if 1.0 <= t <= scroll_end]
        gaps = [round((b - a) * 1000, 1) for a, b in zip(moving, moving[1:])]
        pacing = {"fps": round(len(moving) / max(0.1, scroll_end - 1.0), 1), "interval_p50_ms": pct(gaps, 50),
                  "interval_p95_ms": pct(gaps, 95), "interval_max_ms": max(gaps) if gaps else None,
                  "stalls_over_100ms": sum(1 for g in gaps if g > 100), "jitter_ms": round(statistics.pstdev(gaps), 1) if len(gaps) > 1 else None}
        # OCR every frame of the whole screen's lower and upper strips: page HUD (top
        # of the page) and the overlay (bottom of the page).
        shots = extract(video, os.path.join(cfg_dir, "frames"), (0, 0, 402, 874), step=1)
        texts = ocr([p for _, p in shots])
        g2g, carriers, tap_frames = [], {}, {}
        timeline = []  # (t, carrier) at each change of the overlay's carrier
        for t, p in shots:
            text = texts.get(os.path.basename(p), "")
            mac = re.search(r"mac\s+" + CLOCK, text)
            phone = re.search(r"phone\s+" + CLOCK, text)
            for c in ("wg-rtp", "track", "channel"):
                if re.search(rf"\b{c}\b", text):
                    carriers[c] = carriers.get(c, 0) + 1
                    if not timeline or timeline[-1][1] != c:
                        timeline.append((round(t, 3), c))
            if mac and phone:
                d = wrap(ms_of(phone) - ms_of(mac) - self.a.offset_ms)
                if -50 < d < 5000 and t <= self.a.seconds:
                    g2g.append(d)
            tap = re.search(r"taps\s+(\d+)\s+at\s+" + CLOCK, text)
            if tap and phone:
                n = int(tap.group(1))
                if n not in tap_frames:
                    m2 = re.search(CLOCK, text[tap.start():])
                    tap_frames[n] = (t, ms_of(phone), ms_of(m2) if m2 else None)
        # Taps: the count goes up by one per tap; tap k (0-based) shows count base+k+1.
        counts = sorted(tap_frames)
        inputs, mac_inputs, input_legs = [], [], []
        if counts:
            base = counts[0] - 1 if len(counts) >= len(taps) else max(0, counts[-1] - len(taps))
            for k, t_host in enumerate(taps):
                n = base + k + 1
                if n not in tap_frames:
                    continue
                _, phone_ms, mac_ms = tap_frames[n]
                host_ms = int(t_host * 1000) % 3_600_000
                d = wrap(phone_ms - host_ms)
                if 0 < d < 5000:
                    inputs.append(d)
                if mac_ms is not None:
                    mac_ms = (mac_ms - self.a.offset_ms) % 3_600_000
                    v = wrap(phone_ms - mac_ms)
                    if 0 < v < 5000:
                        mac_inputs.append(v)
                    leg = wrap(mac_ms - host_ms)
                    if -50 < leg < 5000:
                        input_legs.append(leg)
        summary = lambda v: {"n": len(v), "p50": pct(v, 50), "p90": pct(v, 90), "max": max(v) if v else None}
        g2g, misread = drop_misreads(g2g)
        return {"carrier_seen": carriers, "carrier_timeline": timeline, "g2g_ms": summary(g2g), "g2g_ocr_misreads": misread, "pacing": pacing,
                "input_to_frame_ms": summary(inputs), "mac_input_to_frame_ms": summary(mac_inputs),
                "tap_to_mac_ms": summary(input_legs), "video_frames": len(fr)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app")
    ap.add_argument("--configs", default="track,channel,track-relay,channel-relay,track-loss30")
    ap.add_argument("--seconds", type=float, default=12)
    ap.add_argument("--taps", type=int, default=10)
    ap.add_argument("--swipes", type=int, default=0, help="touch scrolls after the taps (end-to-end video)")
    ap.add_argument("--warmup", type=float, default=30,
                    help="seconds of unmeasured streaming (first configuration) after the host starts; 0: none")
    ap.add_argument("--page-scroll", type=int, default=6, help="the bench page's own scroll, css px per frame (0: still)")
    ap.add_argument("--sim-name", default="cmux-mobile-rbvideo-bench")
    ap.add_argument("--phone-ready", action="store_true",
                    help="the phone app is installed and signed in: set up the Mac (pairing seed, bench tab), not the phone")
    ap.add_argument("--surface", action="store_true", help="stream a Mac phone tab (a rig simulator showing the bench page)")
    ap.add_argument("--rig-sim", default="cmux-simsurface-rig", help="--surface: the rig Mac's own simulator")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--skip-setup", action="store_true", help="the phone is signed in and the bench tab exists (a --keep run)")
    ap.add_argument("--record-only", action="store_true", help="record now, analyze later with --analyze")
    ap.add_argument("--out", help="evidence directory (default: a new one)")
    ap.add_argument("--analyze", help="analyze every configuration recorded in this directory")
    ap.add_argument("--remote", help="ssh host whose GUI session runs the Mac app (browser-track-mac.sh)")
    ap.add_argument("--team", help="remote mode: the phone's team id (personal-...)")
    ap.add_argument("--mac-device", help="remote mode: the Mac's cmux-mobile-host device id")
    ap.add_argument("--remote-bundle", default="com.cmuxterm.app.debug.cmuxMobile.rbvideo.b")
    ap.add_argument("--kill-at", type=float, help="hy- configurations: SIGUSR2 to cmux-mobile-host this many seconds into the recording")
    ap.add_argument("--blackhole-at", type=float, nargs="*", help="hy- configurations: SIGUSR1 (toggle) at these seconds")
    ap.add_argument("--offset-ms", type=float, default=0.0, help="Mac clock minus this Mac's clock (clock-offset.py)")
    a = ap.parse_args()
    if a.remote:
        out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "browser-video-track",
                                    datetime.datetime.now().strftime("%H%M%S"))
        os.makedirs(out, exist_ok=True)
        udid = e2e.ensure_sim(a.sim_name, e2e.RUNTIMES["26"], print)
        sim = Sim(udid, os.path.join(out, "shots"))
        bench = Bench(a, print)
        results = []
        for name in a.configs.split(","):
            try:
                results.append(bench.run_config(name, None, sim, None, out))
            except Exception as e:
                print(f"    {name} FAILED: {e}")
                results.append({"config": name, "error": str(e)[:400]})
        json.dump(results, open(os.path.join(out, f"run-{datetime.datetime.now().strftime('%H%M%S')}.json"), "w"), indent=2)
        return
    if a.analyze:
        bench = Bench(a, print)
        results = []
        for name in sorted(os.listdir(a.analyze)):
            cap = os.path.join(a.analyze, name, "capture.json")
            if not os.path.exists(cap):
                continue
            result = json.load(open(cap))
            result.update(bench.analyze(os.path.join(a.analyze, name, "screen.mp4"), os.path.join(a.analyze, name),
                                        result["recording_started_host"], result["taps_host"]))
            json.dump(result, open(os.path.join(a.analyze, name, "result.json"), "w"), indent=2)
            print(json.dumps({k: result.get(k) for k in ("config", "carrier_seen", "g2g_ms", "pacing", "input_to_frame_ms",
                                                         "mac_input_to_frame_ms", "tap_to_mac_ms")}))
            results.append(result)
        json.dump(results, open(os.path.join(a.analyze, "results.json"), "w"), indent=2)
        return
    mac_app = os.path.abspath(a.mac_app)
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    out = a.out or os.path.join(CNX, "verify/evidence", datetime.date.today().isoformat(), "browser-video-track",
                                datetime.datetime.now().strftime("%H%M%S"))
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "run.log"), "a")

    def log(msg):
        line = f"{datetime.datetime.now().strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n"); logf.flush()

    app_path = os.path.join(CNX, "build/dd/Build/Products/Demo-iphonesimulator/CmuxMobileApp.app") if a.no_build else e2e.build_ios(log, "Demo")
    rig = os.path.expanduser(f"~/cmux-next-ios-e2e/{os.path.basename(mac_app)[len('cmux DEV '):-4]}")
    mac = Mac(rig, mac_app)
    if not a.skip_setup or a.phone_ready:
        mac.prepare()
        mac.seed_pairing(names=[a.sim_name])
    page_dir = os.path.join(HERE, "bench-page")
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1"], cwd=page_dir,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    udid = e2e.ensure_sim(a.sim_name, e2e.RUNTIMES["26"], log)
    sim = Sim(udid, os.path.join(out, "shots"))
    results = []
    j = None
    try:
        mac.launch()
        log(f"Mac app up (pid {mac.pid}); cmux-mobile-host {'running' if mac.wait_hostd(120) else 'NOT running'}")
        j = Journey(sim, mac, out, app_path, log)
        if a.skip_setup and not a.phone_ready:
            j.ws_name = "bench"
        for name in ([] if a.skip_setup else a.configs.split(",")[:0]):
            pass
        if a.skip_setup and not a.phone_ready:
            bench = Bench(a, log)
            if a.warmup:
                try:
                    bench.run_config(a.configs.split(",")[0], mac, sim, j, out, warmup=a.warmup)
                except Exception as e:  # a failed warm-up is logged, the measured configurations still run
                    log(f"    warm-up FAILED: {e}")
            for name in a.configs.split(","):
                try:
                    results.append(bench.run_config(name, mac, sim, j, out))
                except Exception as e:
                    log(f"    {name} FAILED: {e}")
                    results.append({"config": name, "error": str(e)[:400]})
            return
        j.seed_mac()
        ws = mac.cmux("workspace", "create", "--name", "bench", json_out=True)["value"]
        url = f"http://127.0.0.1:{PORT}/bench.html?scroll={a.page_scroll}"
        if a.surface:
            rig = e2e.ensure_sim(a.rig_sim, e2e.RUNTIMES["26"], log)
            subprocess.run(["xcrun", "simctl", "bootstatus", rig, "-b"], check=True, capture_output=True)
            subprocess.run(["xcrun", "simctl", "openurl", rig, url], check=True)
            # The daemon's own call, as the Mac's phone.show makes the tab.
            # The daemon names workspaces by number; the CLI's id is the public one.
            listed = daemon_rpc(mac, {"id": 1, "cmd": "list-workspaces"}) or {}
            numeric = next((w["id"] for w in (listed.get("data") or {}).get("workspaces", []) if w.get("name") == "bench"), None)
            tab = daemon_rpc(mac, {"id": 2, "cmd": "new-conversation-tab", "workspace": numeric,
                                   "page": "phone", "route": f"sim:{rig}"})
            log(f"bench workspace {ws['workspace_id']}, phone tab {tab} of rig simulator {rig}")
        else:
            tab = mac.cmux("tab", "create", "browser", "--workspace", ws["workspace_id"], "--url", url, json_out=True)
            log(f"bench workspace {ws['workspace_id']}, browser tab {tab}")
        if tab and isinstance(tab, dict) and tab.get("value", {}).get("tab_id"):
            mac.cmux("tab", tab["value"]["tab_id"], "focus", check=False)
        mac.cmux("tab", ws["tab_id"], "close", check=False)
        for sid, title, owner, fn in j.plan():
            if a.phone_ready and sid != "mac_discovered":
                continue
            if sid in ("fresh_install", "sign_in", "choose_space", "mac_discovered"):
                j.step(sid, title, owner, fn)
        bench = Bench(a, log)
        if a.warmup:
            try:
                bench.run_config(a.configs.split(",")[0], mac, sim, j, out, warmup=a.warmup)
            except Exception as e:  # a failed warm-up is logged, the measured configurations still run
                log(f"    warm-up FAILED: {e}")
        for name in a.configs.split(","):
            try:
                results.append(bench.run_config(name, mac, sim, j, out))
            except Exception as e:  # one configuration's failure does not end the run
                log(f"    {name} FAILED: {e}")
                results.append({"config": name, "error": str(e)[:400]})
    finally:
        json.dump({"mac_app": os.path.basename(mac_app), "results": results},
                  open(os.path.join(out, f"run-{datetime.datetime.now().strftime('%H%M%S')}.json"), "w"), indent=2)
        server.terminate()
        if not a.keep:
            log(f"quitting the rig Mac app: {mac.quit()}")
            subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", udid], capture_output=True)
            log(f"simulator {a.sim_name} deleted")
        log(f"results: {os.path.join(out, 'results.json')}")


if __name__ == "__main__":
    main()
