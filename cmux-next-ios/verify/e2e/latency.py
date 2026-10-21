"""Latency metrics, measured black-box from the simulator's own screen recording.

The AX tree takes ~2.5 s per read, far too coarse, so every metric is read from
`simctl io recordVideo` frames (variable frame rate, up to 60 fps, each frame
with its presentation time):

- keystroke -> echo: both ends are in the video. t0 is the first frame where
  the touched software key changes (its key-down highlight); t1 is the first
  frame where the terminal's cursor line changes. No clock mapping at all.
- the rest (cold connect, warm reconnect, tab switch): t0 is the host time of
  the launch or tap, mapped into video time with the offset measured from the
  recording's start; t1 is the first frame after which the watched region
  stays equal to its final, settled look. Accuracy is about one frame plus the
  start-offset error (tens of ms), fine for targets of 1 to 1.5 s.
"""
import json
import os
import random
import statistics
import subprocess
import tempfile
import time

SCALE = 3  # iPhone 17 Pro: 3 px per point


def frames(video, region_pts, fps_cap=None):
    """[(pts_seconds, bytes)] of the cropped region (points) for every frame."""
    x, y, w, h = [int(v * SCALE) for v in region_pts]
    w -= w % 2; h -= h % 2
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "frame=pts_time",
                            "-of", "csv=p=0", video], capture_output=True, text=True)
    times = [float(t.strip(",")) for t in probe.stdout.split() if t.strip(",") and t.strip(",") != "N/A"]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-fps_mode", "passthrough", "-vf", f"crop={w}:{h}:{x}:{y},format=gray",
                          "-f", "rawvideo", "-"], capture_output=True).stdout
    n = w * h
    out = []
    for i in range(min(len(times), len(raw) // n)):
        out.append((times[i], raw[i * n:(i + 1) * n]))
    return out


def diff(a, b, step=7):
    """Mean absolute difference over sampled pixels (0..255)."""
    if len(a) != len(b):
        return 255.0
    s = 0; c = 0
    for i in range(0, len(a), step):
        s += abs(a[i] - b[i]); c += 1
    return s / max(c, 1)


def first_change(fr, after_t, threshold=2.0):
    """First frame time > after_t whose region differs from the frame just before after_t."""
    base = None
    for t, img in fr:
        if t <= after_t:
            base = img
            continue
        if base is None:
            base = img
            continue
        if diff(base, img) > threshold:
            return t
    return None


def settle_time(fr, after_t, until_t=None, threshold=2.0):
    """First frame time > after_t after which the region equals its final look (within the window)."""
    win = [(t, img) for t, img in fr if t > after_t and (until_t is None or t <= until_t)]
    if not win:
        return None
    final = win[-1][1]
    settled = None
    for t, img in win:
        if diff(final, img) <= threshold:
            if settled is None:
                settled = t
        else:
            settled = None
    return settled


class DeviceLog:
    """The app's `timing` lines (ConnectTimeline), each with its wall-clock time.

    The simulator shares the host clock, so a line's timestamp maps into a
    recording exactly like a host time does."""

    def __init__(self, udid):
        import threading
        self.lines = []  # (epoch seconds, message)
        self.proc = subprocess.Popen(
            ["xcrun", "simctl", "spawn", udid, "log", "stream", "--style", "ndjson", "--level", "info",
             "--predicate", 'subsystem == "dev.cmux.mobile" AND category == "timing"'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()
        time.sleep(1.0)  # `log stream` attaches before the first measured event

    def _read(self):
        import datetime
        for line in self.proc.stdout:
            try:
                ev = json.loads(line)
            except ValueError:
                continue
            msg = ev.get("eventMessage", "")
            ts = ev.get("timestamp", "")
            try:
                when = datetime.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S.%f%z").timestamp()
            except ValueError:
                continue
            self.lines.append((when, msg))

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()

    def find(self, needle, after, before=None):
        """[(time, message)] of lines containing `needle` within [after, before)."""
        return [(t, m) for t, m in self.lines if needle in m and t >= after and (before is None or t < before)]

    @staticmethod
    def since_start_ms(message):
        """The `(<n>ms)` since-process-start figure of a timing line."""
        import re
        m = re.search(r"\((\d+)ms\)", message)
        return int(m.group(1)) if m else None


def summarize(samples):
    s = sorted(x for x in samples if x is not None)
    if not s:
        return {"n": 0}
    p95 = s[min(len(s) - 1, int(round(0.95 * (len(s) - 1))))]
    return {"n": len(s), "median_ms": round(statistics.median(s) * 1000), "p95_ms": round(p95 * 1000),
            "min_ms": round(s[0] * 1000), "max_ms": round(s[-1] * 1000), "failed": len(samples) - len(s)}


class Latency:
    def __init__(self, journey, out_dir, log, samples=20, max_load=None):
        self.j, self.sim, self.mac = journey, journey.sim, journey.mac
        self.out, self.log, self.n = out_dir, log, samples
        self.max_load = max_load
        os.makedirs(out_dir, exist_ok=True)
        self.metrics = {}
        self.loads = []

    def gate(self, limit_s=300):
        """Load gate: before a sample, wait (at most `limit_s`) until this Mac's
        1-minute load average is at or under `max_load`, so before/after runs
        compare at matched load. Records the load each sample ran at."""
        waited = 0
        while self.max_load is not None and os.getloadavg()[0] > self.max_load and waited < limit_s:
            if waited == 0:
                self.log(f"    load {os.getloadavg()[0]:.1f} > {self.max_load}: waiting")
            time.sleep(5); waited += 5
        load = round(os.getloadavg()[0], 1)
        self.loads.append(load)
        return load

    def load_summary(self, start):
        loads = self.loads[start:]
        if not loads:
            return {}
        return {"load_1min_median": statistics.median(loads), "load_1min_max": max(loads), "max_load_gate": self.max_load}

    def video(self, name):
        return os.path.join(self.out, f"{name}.mp4")

    # ---------------------------------------------------------------- keystroke echo
    def keystroke_echo(self, flood=False):
        name = "keystroke_echo_flood" if flood else "keystroke_echo_idle"
        j = self.j
        term = j.seed["term1"]
        j.back_to_list(); j.open_seed_workspace()
        if flood:
            # Output flood on the top rows only, so the prompt line stays measurable.
            # ~100 screen updates per second for at most 60 s (self-ending), top row only.
            j.mac_write(term, "(for i in $(seq 1 6000); do printf '\\0337\\033[1;1H%s %s %s\\0338' $i $RANDOM $RANDOM; sleep 0.01; done) & FLOODPID=$!\n")
            time.sleep(1.0)
        j.focus_terminal()
        # The page can be left scrolled up with the prompt off screen (typing does not
        # scroll back to the cursor); bring the prompt into view first.
        jump = self.sim.find(label="Scroll to bottom")
        if jump:
            self.sim.tap_el(jump[0]); time.sleep(1.0)
            self.metrics.setdefault("notes", []).append(f"{name}: the terminal was scrolled up with the prompt off screen; tapped Scroll to bottom")
        keys = self.sim.keyboard()
        letters = [k for k in "asdfghjkl" if k in keys]
        comp = self.sim.find(ident="terminal.composer.field")
        line_bottom = comp[0].frame[1] - 4 if comp else 640
        line_region = (0, line_bottom - 40, 402, 38)
        samples, taps = [], []
        vid = self.video(name)
        self.sim.record_start(vid)
        time.sleep(0.8)
        for i in range(self.n):
            k = keys[random.choice(letters)]
            taps.append((k.label, k.frame))
            self.sim.tap_el(k)
            time.sleep(0.45)
        time.sleep(0.5)
        self.sim.record_stop()
        # Clean the line on the Mac side and stop the flood.
        j.mac.cmux("terminal", term, "keys", "ctrl+u", check=False)
        if flood:
            j.mac_write(term, "kill $FLOODPID 2>/dev/null\n")
        j.hide_keyboard()
        # Analyse: key-down (key region changes) -> echo (line region changes).
        line = frames(vid, line_region)
        for idx, (label, (kx, ky, kw, kh)) in enumerate(taps):
            # Key popup grows above the key; watch the key and the popup above it.
            kfr = frames(vid, (max(kx - 4, 0), max(ky - 60, 0), min(kw + 8, 402 - max(kx - 4, 0)), kh + 60))
            # Search windows: taps are ~0.45+ s apart; locate this tap's key-down in order.
            if idx == 0:
                self._cursor = 0.3
            t0 = first_change(kfr, self._cursor, threshold=1.0)
            if t0 is None:
                samples.append(None); continue
            t1 = first_change(line, t0 - 0.001, threshold=0.2)
            samples.append((t1 - t0) if t1 is not None and t1 - t0 < 1.5 else None)
            self._cursor = t0 + 0.3
        self.metrics[name] = summarize(samples) | {"video": os.path.basename(vid),
                                                   "taps": [[l, list(f)] for l, f in taps], "line_region": list(line_region)}
        self.log(f"    {name}: {self.metrics[name]}")

    # ---------------------------------------------------------------- connects
    def _status_region(self):
        s = self.sim.find(ident="mac-link-status")
        return s[0].frame if s else (0, 160, 402, 30)

    def _list_region(self):
        return (0, 150, 402, 300)

    def cold_connect(self):
        """Kill + launch, n times. Per launch:
        - cold_connect_to_list: the app's process start (its own timing line) to the
          list region settled with the Mac's rows (video). The settle window ends
          when the rig terminates the app for the next launch: an earlier rig took
          the window to the next launch's host time minus 1 s, which under load fell
          after the next terminate, so the home screen became the 'final look' and
          the metric read the gap between launches (about 4 s), not the app.
        - cold_app_live / cold_app_cached: the app's own marks (process start to the
          first live / cached workspace row on screen).
        - cold_link_up: process start (simctl launch) to cmux-mobile-host logging the link up."""
        j = self.j
        j.back_to_list()
        region = self._list_region()
        samples, links, lives, cached, spawn = [], [], [], [], []
        vid = self.video("cold_connect")
        dlog = DeviceLog(self.sim.udid)
        t_rec = self.sim.record_start(vid)
        launches, terms = [], []
        load0 = len(self.loads)
        for i in range(self.n):
            self.gate()
            terms.append(time.time() - t_rec)
            self.sim.terminate("dev.cmux.mobile")
            time.sleep(1.0)
            t_call = time.time()
            # -cmux-mobile-tab (DEBUG) only picks the first tab, so the list is on screen from launch.
            t = self.sim.launch("dev.cmux.mobile", args=("-cmux-mobile-tab", "workspaces"))
            launches.append((t_call, t))
            up = None
            while time.time() - t < 20 and up is None:
                ev = [e for e in self.mac.link_events(t) if e[1] == "up"]
                up = ev[0][0] - t if ev else None
                time.sleep(0.3)
            links.append(up)
            ok = self.sim.wait(prefix=j.ws_name, kind="Button", timeout=15)
            if not ok:
                launches[-1] = None
            time.sleep(1.5)
        terms.append(time.time() - t_rec)
        self.sim.record_stop()
        time.sleep(1.0)
        dlog.stop()
        fr = frames(vid, region)
        starts = []
        for i, l in enumerate(launches):
            if l is None:
                starts.append(None); samples.append(None); continue
            t_call, t_ret = l
            # The process start, from the app's first timing line after the launch call.
            first = dlog.find("timing launch ", t_call - 0.05, t_call + 15)
            p0 = None
            if first:
                when, msg = first[0]
                ms = DeviceLog.since_start_ms(msg)
                p0 = when - ms / 1000.0 if ms is not None else None
            live = dlog.find("timing launch workspace_row_live", t_call - 0.05, t_call + 20)
            cache = dlog.find("timing launch workspace_row_cached", t_call - 0.05, t_call + 20)
            lives.append(DeviceLog.since_start_ms(live[0][1]) / 1000.0 if live else None)
            cached.append(DeviceLog.since_start_ms(cache[0][1]) / 1000.0 if cache else None)
            if p0 is not None:
                spawn.append(t_ret - p0)
                links[i] = None if links[i] is None else links[i] + (t_ret - p0)
            t0 = (p0 if p0 is not None else t_ret) - t_rec
            starts.append(t0)
            end = terms[i + 1] - 0.05
            # Dimmed (cached) rows turning live is a small change in pixels: a low
            # threshold, and never earlier than the app's own live-row mark.
            t1 = settle_time(fr, t0, end, threshold=0.25)
            if t1 is not None and live and p0 is not None:
                t1 = max(t1, live[0][0] - t_rec)
            samples.append((t1 - t0) if t1 else None)
        self.metrics["cold_connect_to_list"] = summarize(samples) | {"video": os.path.basename(vid), "load_1min": round(os.getloadavg()[0], 1),
            "raw_ms": [None if x is None else round(x * 1000) for x in samples], **self.load_summary(load0),
            "note": "process start (the app's timing line) to the list region settled with the Mac's live rows (video, and never before the app's workspace_row_live mark); window ends at the next terminate"}
        self.metrics["cold_app_live"] = summarize(lives) | {"note": "app mark: process start to the first live workspace row on screen"}
        self.metrics["cold_app_cached"] = summarize(cached) | {"note": "app mark: process start to the first cached workspace row on screen"}
        self.metrics["cold_link_up"] = summarize(links) | {"note": "process start to cmux-mobile-host logging the phone's link up"}
        self.metrics["cold_launch_return"] = summarize(spawn) | {"note": "rig overhead: process start to `simctl launch` returning"}
        self.log(f"    cold: {self.metrics['cold_connect_to_list']} live(app): {self.metrics['cold_app_live']} link: {self.metrics['cold_link_up']}")

    def warm_reconnect(self, background_s=20):
        """Home, `background_s` in background, foreground. Measured on the Mac side: the
        foreground to cmux-mobile-host's next link up when the link dropped in background."""
        j = self.j
        j.back_to_list()
        samples, survived = [], 0
        for i in range(self.n):
            self.sim.home()
            t_bg = time.time()
            time.sleep(background_s)
            t = self.sim.launch("dev.cmux.mobile", terminate=False)
            up = None
            while time.time() - t < 15 and up is None:
                ev = [e for e in self.mac.link_events(t) if e[1] == "up"]
                up = ev[0][0] - t if ev else None
                time.sleep(0.2)
            if up is None and not [e for e in self.mac.link_events(t_bg) if e[1] == "down"]:
                survived += 1
                up = 0.0  # the link never dropped: nothing to reconnect
            samples.append(up)
            time.sleep(1.0)
        self.metrics["warm_reconnect"] = summarize(samples) | {
            "note": f"after {background_s} s in background: foreground to cmux-mobile-host's link up; {survived} of {self.n} links survived the background (0 ms)"}
        self.log(f"    warm: {self.metrics['warm_reconnect']}")

    def tab_switch(self):
        """Grid -> card tap, n times, alternating two terminal tabs. t0 is the touch
        as the app sees it (its `tab_activate` timing event, mapped into the video);
        an `axe tap` takes 0.3 to 0.7 s from the host call to the touch under load, so
        the host call time is reported separately (tab_switch_host). The settle
        window ends at the next tap on the Tabs button (an earlier rig ended it
        2.5 s before the next card tap, which could fall after the grid had opened
        again: the grid became the 'final look')."""
        j = self.j
        j.back_to_list(); j.open_seed_workspace()
        samples, host_samples, first = [], [], []
        vid = self.video("tab_switch")
        dlog = DeviceLog(self.sim.udid)
        t_rec = self.sim.record_start(vid)
        taps, grid_taps = [], []
        load0 = len(self.loads)
        for i in range(self.n):
            name = "e2e-t2" if i % 2 == 0 else "e2e-t1"
            self.gate()
            grid_taps.append(time.time() - t_rec)
            self.sim.tap_q(label="Tabs", kind="Button")
            cand = self.sim.wait(contains=name, timeout=8)
            if not cand:
                taps.append(None); continue
            t = self.sim.tap_el(cand)
            taps.append(t)
            time.sleep(1.5)
        grid_taps.append(time.time() - t_rec)
        self.sim.record_stop()
        time.sleep(1.0)
        dlog.stop()
        fr = frames(vid, (0, 100, 402, 560))
        for i, t in enumerate(taps):
            if t is None:
                samples.append(None); host_samples.append(None); first.append(None); continue
            act = dlog.find("timing event tab_activate", t - 0.05, t + 5)
            th = t - t_rec
            t0 = (act[0][0] - t_rec) if act else None
            end = grid_taps[i + 1] - 0.05
            t1 = settle_time(fr, t0 if t0 is not None else th, end)
            host_samples.append((t1 - th) if t1 else None)
            if t0 is None:
                samples.append(None); first.append(None); continue
            samples.append((t1 - t0) if t1 else None)
            tc = first_change(fr, t0 - 0.001, threshold=1.0)
            first.append((tc - t0) if tc is not None and tc < end else None)
        self.metrics["tab_switch"] = summarize(samples) | {"video": os.path.basename(vid), "load_1min": round(os.getloadavg()[0], 1),
            "raw_ms": [None if x is None else round(x * 1000) for x in samples], **self.load_summary(load0),
            "note": "touch (app's tab_activate event) on a tab card in the grid to the terminal page settled (includes TabsKit's zoom)"}
        self.metrics["tab_switch_first_frame"] = summarize(first) | {
            "note": "touch to the first changed frame (the zoom starts)"}
        self.metrics["tab_switch_host"] = summarize(host_samples) | {
            "note": "host `axe tap` call to the page settled (the old definition; includes axe's delivery time)"}
        self.log(f"    tab switch: {self.metrics['tab_switch']} first frame: {self.metrics['tab_switch_first_frame']} host: {self.metrics['tab_switch_host']}")

    def run(self, which=None):
        plan = [("keystroke_echo_idle", lambda: self.keystroke_echo(False)),
                ("keystroke_echo_flood", lambda: self.keystroke_echo(True)),
                ("tab_switch", self.tab_switch),
                ("cold_connect_to_list", self.cold_connect),
                ("warm_reconnect", self.warm_reconnect)]
        for key, fn in plan:
            if which and key not in which:
                continue
            try:
                fn()
            except Exception as e:  # a metric failing must not stop the others
                self.metrics[key] = {"n": 0, "error": str(e)[:300]}
                self.log(f"    {key} ERROR {e}")
                try:
                    self.sim.record_stop()
                except Exception:
                    pass
        self.metrics["agent_first_token"] = {"n": 0, "blocked": "no credit-free real harness (see agent_chat)"}
        self.metrics["feed_answer_round_trip"] = {"n": 0, "blocked": "no agent asks without a harness (see feed)"}
        return self.metrics
