#!/usr/bin/env python3
"""Browser freeze soak (verify/browser-freeze/README.md): the phone streams Mac browser tabs
over the real link and is driven for 10+ minutes (scroll, tap links, type, back/forward,
idle, a second and third tab from their own browser host processes, tab switches, an
optional background). It measures the phone's decoded frames (the app's
`browser <tab>: N fps` os_log line, one per 30 shown frames), the input round trip
(gesture -> Mac -> video -> a changed screenshot), and the rig Mac's
`browser: media lane ... keyframe_requests=` and `media lane switched route` lines, and
captures evidence the moment a freeze shows:

- host: keyframe_requests growing > 2/s for >= 5 s (PLIs from the phone that never end);
- phone: two gestures in a row with no screen change for 8 s while on a streamed tab.

Runs on the simulator mini through relay.py (the minis cannot ssh to each other):

    python3 -u relay.py SIM_HOST REMOTE_DIR -- --app APP --sim cmux-brfz \
        --rig HOST:RIGDIR:WORKSPACE --out DIR --creds FILE [--reuse] \
        [--config default|wgonly|relay|loss] [--drop-permille 30] [--bg 20]

Only the existing rig tooling drives the phone: simctl, AXe touches into the simulator,
the software keyboard; nothing is fronted or focused on any Mac.
"""
import argparse
import datetime
import json
import os
import random
import re
import shlex
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "e2e"))
import link_soak as ls  # noqa: E402
import transport_verify as tv  # noqa: E402
from journey import Fail, Journey, check  # noqa: E402
from sim import Sim, sh  # noqa: E402

TS = r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z"
KF_RATE = 2.0  # keyframe requests per second that count as a storm
KF_SPAN = 5.0  # seconds the storm must last


def utc(epoch=None):
    return datetime.datetime.fromtimestamp(epoch or time.time(), datetime.timezone.utc).strftime("%H:%M:%S")


class Run:
    def __init__(self, a):
        self.a = a
        self.out = a.out
        os.makedirs(os.path.join(self.out, "shots"), exist_ok=True)
        self.logf = open(os.path.join(self.out, "run.log"), "a")
        self.actions = open(os.path.join(self.out, "actions.jsonl"), "a")
        self.lock = threading.Lock()
        self.host_lines = []  # (epoch, line)
        self.kf = []  # (epoch, keyframe_requests max of the batch)
        self.lane = []  # parsed media lane reports
        self.host_events = []
        self.oslog = []  # (epoch, line)
        self.fps_lines = []  # (epoch, tab, fps, carrier)
        self.decode_failed = []
        self.tab_keys = {}  # name -> phone tab key
        self.current = None  # tab name on screen
        self.storm_since = None
        self.freezes = []
        self.last_capture = 0
        self.no_response = 0
        self.stop = threading.Event()
        self.depth = {}
        self.rows = {}

    # ---- logging ---------------------------------------------------------
    def log(self, msg):
        line = f"{utc()} {msg}"
        print(line, flush=True)
        self.logf.write(line + "\n")
        self.logf.flush()

    def record(self, **rec):
        rec = {"t": round(time.time(), 2), "utc": utc(), "tab": self.current, **rec}
        self.actions.write(json.dumps(rec) + "\n")
        self.actions.flush()
        self.log(f"act {json.dumps(rec)}")
        return rec

    # ---- the rig Mac's hostd log, read incrementally ----------------------
    def start_host_monitor(self):
        r = self.rig.ssh(f"cd {self.rig.dir} && python3 -c 'import rig; print(rig.mac().hostd_state)'")
        self.host_path = r.stdout.strip() + "/cmux-mobile-host.log"
        size = self.rig.ssh(f"stat -f %z {shlex.quote(self.host_path)}").stdout.strip()
        self.host_off = int(size or 0)
        self.host_file = open(os.path.join(self.out, "hostd-live.log"), "a")
        threading.Thread(target=self._host_loop, daemon=True).start()

    def _host_loop(self):
        while not self.stop.wait(5):
            try:
                self._host_poll()
            except Exception as error:  # a missed poll is a gap, not the end of the run
                self.log(f"host poll failed: {str(error)[:120]}")

    def _host_poll(self):
        p = shlex.quote(self.host_path)
        r = self.rig.ssh(f"s=$(stat -f %z {p}); echo $s; tail -c +{self.host_off + 1} {p} | head -c $((s-{self.host_off}))",
                         timeout=40)
        if r.returncode != 0 or not r.stdout:
            return
        head, _, text = r.stdout.partition("\n")
        size = int(head.strip() or 0)
        if size < self.host_off:  # rotated or recreated
            self.host_off = 0
            return
        self.host_off = size
        self.host_file.write(text)
        self.host_file.flush()
        batch_max = None
        batch_t = None
        for line in text.splitlines():
            m = re.match(TS + r" +\w+ (\S+): (.*)", line)
            if not m:
                continue
            t = ls.epoch_of(m.group(1))
            body = m.group(3)
            with self.lock:
                self.host_lines.append((t, line))
                del self.host_lines[:-3000]
            if body.startswith("browser: media lane"):
                f = dict(re.findall(r"(\w+)=([\w.]+)", body))
                rec = {"t": t, **{k: f.get(k) for k in ("frames", "keyframe_requests", "loss", "target_kbps", "packets", "nacks")}}
                self.lane.append(rec)
                kf = int(f.get("keyframe_requests", 0))
                if batch_max is None or kf > batch_max:
                    batch_max, batch_t = kf, t
            elif re.search(r"switched route|takes the media lane back|took the media lane|link up|link down|"
                           r"media session (up|down|failed)|link path changed|stalled", body):
                ev = {"t": t, "utc": utc(t), "line": body[:240]}
                self.host_events.append(ev)
                self.log(f"host {utc(t)} {body[:200]}")
        if batch_max is not None:
            self._kf_point(batch_t, batch_max)

    def _kf_point(self, t, kf):
        prev = self.kf[-1] if self.kf else None
        self.kf.append((t, kf))
        if not prev or kf < prev[1] or t <= prev[0]:
            return
        rate = (kf - prev[1]) / (t - prev[0])
        if rate > KF_RATE:
            self.storm_since = self.storm_since or prev[0]
            if t - self.storm_since >= KF_SPAN:
                self.freeze("keyframe-storm", f"keyframe_requests {prev[1]}->{kf} in {t - prev[0]:.1f}s "
                                              f"({rate:.1f}/s) since {utc(self.storm_since)}")
        else:
            if self.storm_since:
                self.log(f"keyframe storm ended at {utc(t)} (started {utc(self.storm_since)}, kf={kf})")
                self.host_events.append({"t": t, "utc": utc(t), "line": f"[driver] keyframe storm ended, began {utc(self.storm_since)}"})
            self.storm_since = None

    # ---- the phone's os_log (dev.cmux.mobile) ----------------------------
    def start_oslog(self):
        path = os.path.join(self.out, "oslog-stream.log")
        self.oslog_proc = subprocess.Popen(
            ["xcrun", "simctl", "spawn", self.udid, "log", "stream", "--level", "debug", "--style", "compact",
             "--predicate", 'subsystem BEGINSWITH "dev.cmux"'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, errors="replace")
        f = open(path, "a")

        def loop():
            for line in self.oslog_proc.stdout:
                now = time.time()
                f.write(line)
                f.flush()
                with self.lock:
                    self.oslog.append((now, line.rstrip()))
                    del self.oslog[:-4000]
                m = re.search(r"browser (\S+): (\d+) fps .* via (\S+)", line)
                if m:
                    self.fps_lines.append((now, m.group(1), int(m.group(2)), m.group(3)))
                m = re.search(r"browser (\S+): open at (\S+)", line)
                if m:
                    self.log(f"phone tab {m.group(1)} opens {m.group(2)}")
                    self.last_open_key = m.group(1)
                if "decode failed" in line or "no decoder" in line or "bad parameter sets" in line:
                    self.decode_failed.append((now, line.strip()[:240]))
                    self.log(f"phone {line.strip()[-160:]}")
        threading.Thread(target=loop, daemon=True).start()

    # ---- freeze evidence ---------------------------------------------------
    def freeze(self, kind, detail):
        now = time.time()
        rec = {"t": now, "utc": utc(now), "kind": kind, "detail": detail, "tab": self.current,
               "since_start_s": round(now - self.t0, 1)}
        self.freezes.append(rec)
        self.log(f"FREEZE {kind}: {detail}")
        if now - self.last_capture < 60:
            return
        self.last_capture = now
        d = os.path.join(self.out, f"freeze-{len(self.freezes):02d}-{kind}-{utc(now).replace(':', '')}")
        os.makedirs(d, exist_ok=True)
        with self.lock:
            host = [l for _, l in self.host_lines[-600:]]
            osl = [l for _, l in self.oslog[-800:]]
        open(os.path.join(d, "hostd-tail.log"), "w").write("\n".join(host) + "\n")
        open(os.path.join(d, "oslog-tail.log"), "w").write("\n".join(osl) + "\n")
        phone = self.phone_stderr()
        open(os.path.join(d, "phone-stderr-tail.log"), "w").write("\n".join(phone.splitlines()[-1500:]) + "\n")
        try:
            r = subprocess.run(["xcrun", "simctl", "spawn", self.udid, "log", "show", "--last", "3m", "--info", "--debug",
                                "--style", "compact", "--predicate", 'subsystem BEGINSWITH "dev.cmux"'],
                               capture_output=True, text=True, timeout=120)
            open(os.path.join(d, "oslog-show-3m.log"), "w").write(r.stdout)
        except subprocess.TimeoutExpired:
            pass
        subprocess.run(["xcrun", "simctl", "io", self.udid, "screenshot", os.path.join(d, "screen.png")],
                       capture_output=True, timeout=60)
        json.dump({**rec, "kf_last": self.kf[-30:], "lane_last": self.lane[-30:], "fps_last": self.fps_lines[-20:],
                   "decode_failed": self.decode_failed[-20:], "host_events": self.host_events[-30:], "tabs": self.tab_keys},
                  open(os.path.join(d, "summary.json"), "w"), indent=2)
        self.log(f"captured {d}")

    def phone_stderr(self):
        text = ""
        for f in sorted(os.listdir(self.out)):
            if f.startswith("phone-stderr.log."):
                text += open(os.path.join(self.out, f), errors="replace").read()
        return text

    # ---- screen change (the input round trip) ------------------------------
    def sig(self):
        tmp = f"/tmp/brfz-{self.udid}.png"
        try:
            subprocess.run(["xcrun", "simctl", "io", self.udid, "screenshot", tmp], capture_output=True, timeout=30)
            r = subprocess.run([self.imgsig, tmp, str(self.a.page_y0), str(self.a.page_y1)], capture_output=True, text=True, timeout=30)
            return bytes.fromhex(r.stdout.strip()) if r.returncode == 0 else None
        except (subprocess.TimeoutExpired, ValueError):
            return None

    @staticmethod
    def diff(a, b):
        if a is None or b is None or len(a) != len(b):
            return 0.0
        return sum(abs(x - y) for x, y in zip(a, b)) / len(a)

    def changed_after(self, before, t_input, timeout=8.0):
        """Seconds from the input until the page area differs from `before`, or None."""
        while time.time() - t_input < timeout:
            s = self.sig()
            if self.diff(before, s) > self.a.change_threshold:
                return round(time.time() - t_input, 2)
        return None

    def responded(self, what, rtt, **extra):
        rec = self.record(act=what, rtt=rtt, **extra)
        if rtt is None:
            self.no_response += 1
            if self.no_response >= 2:
                self.freeze("phone-unresponsive", f"{self.no_response} inputs in a row with no screen change in 8 s "
                                                  f"(last: {what} on {self.current})")
        else:
            self.no_response = 0
        return rec

    # ---- actions ----------------------------------------------------------------
    def scroll(self, down=True):
        before = self.sig()
        y0, y1 = (640, 300) if down else (300, 640)
        t = time.time()
        self.sim.swipe(200, y0, 200 + random.randint(-20, 20), y1, duration=0.35)
        return self.responded("scroll-down" if down else "scroll-up", self.changed_after(before, t))

    def reconnecting(self):
        """Whether the page shows the app's reconnect notice."""
        try:
            return [t for t in self.sim.texts() if re.search(r"Reconnecting|reconnect", t, re.I)][:3]
        except Exception:
            return []

    def long_scroll(self, seconds=12):
        """Continuous pans for `seconds` (no pause longer than the swipe itself), then a
        reconnect check: a long scroll must never end the stream."""
        before = self.sig()
        t = time.time()
        n = 0
        while time.time() - t < seconds:
            down = (n // 4) % 2 == 0
            self.sim.swipe(200, 680 if down else 260, 200, 260 if down else 680, duration=0.3)
            n += 1
        rtt = self.changed_after(before, time.time(), timeout=4)
        seen = self.reconnecting()
        return self.responded("long-scroll", 0.0 if self.diff(before, self.sig()) > self.a.change_threshold else rtt,
                              swipes=n, seconds=round(time.time() - t, 1), reconnecting=seen)

    def still_idle(self, seconds):
        """A still page left alone; then the reconnect check and one scroll."""
        self.record(act="still-idle", seconds=seconds)
        time.sleep(seconds)
        self.record(act="still-idle-end", reconnecting=self.reconnecting())
        if self.a.plan != "shown":
            self.scroll(True)

    def tap_link(self):
        before = self.sig()
        x, y = random.randint(60, 340), random.randint(250, 620)
        t = time.time()
        self.sim.tap(x, y)
        rtt = self.changed_after(before, t, timeout=10)
        if rtt is not None:
            self.depth.setdefault(self.current, [0, 0])[:] = [self.depth.get(self.current, [0, 0])[0] + 1, 0]
        return self.responded("tap", rtt, at=[x, y])

    def history(self, op):
        # Back only over pages this run opened by a tap or search (back from the tab's first
        # page goes to its blank start page, and every later input then shows no change).
        depth = self.depth.setdefault(self.current, [0, 0])  # [back steps, forward steps]
        if (op == "back" and depth[0] <= 0) or (op == "forward" and depth[1] <= 0):
            return self.record(act=op, skipped="no history from this run")
        b = self.tv.toolbar_button(*(("Back", "BackButton", "Go Back") if op == "back" else ("Forward", "Go Forward")))
        if not b:
            return self.record(act=op, skipped="no button")
        before = self.sig()
        t = time.time()
        self.sim.tap_el(b)
        rtt = self.changed_after(before, t, timeout=10)
        if rtt is not None:
            d = self.depth[self.current]
            d[0], d[1] = (d[0] - 1, d[1] + 1) if op == "back" else (d[0] + 1, d[1] - 1)
        return self.responded(op, rtt)

    def search(self):
        """Types a marker into the page's own search box when the tap brings up the keyboard,
        else navigates to a search URL from the address bar; the round trip ends when the
        marker shows on the phone (OCR of the streamed page)."""
        self.n_marker = getattr(self, "n_marker", 0) + 1
        marker = f"brfz{self.n_marker:03d}"
        via = "address-bar"
        field = [o for o in self.sim.ocr() if re.search(r"^search", o[4], re.I) and self.a.page_y0 < o[1] < self.a.page_y1]
        if field:
            x, y, w, h, _ = field[0]
            self.sim.tap(x + w / 2, y + h / 2)
            time.sleep(1.5)
            if self.sim.keyboard():
                via = "page-field"
                t = time.time()
                self.sim.softtype(marker + "\n")
        if via == "address-bar":
            self.j.hide_keyboard()
            # Letters, digits, '.' and '/' only: every key is on the first two layouts.
            url = f"en.wikipedia.org/wiki/{marker}"
            t = time.time()
            try:
                self.tv.type_url(url)
            except Exception as error:
                self.close_editing()
                return self.record(act="search", error=str(error)[:160])
        t_typed = time.time()
        seen = None
        while time.time() - t_typed < 25:
            if any(marker in o[4] for o in self.sim.ocr() if o[1] > self.a.page_y0):
                seen = round(time.time() - t_typed, 2)
                break
            time.sleep(0.5)
        self.close_editing()
        return self.responded("search", seen, via=via, marker=marker, type_s=round(t_typed - t, 2))

    def close_editing(self):
        """Leaves an address field that is still editing (its X button), then the keyboard."""
        for e in self.sim.find(kind="Button"):
            if (e.label in ("Close", "Cancel", "Done") or (e.ident or "").endswith("cancel")) and 600 < e.center[1] < 874:
                self.sim.tap_el(e)
                time.sleep(0.8)
                break
        self.j.hide_keyboard()

    def interact(self, seconds):
        end = time.time() + seconds
        ops = [lambda: self.scroll(True), lambda: self.scroll(True), lambda: self.scroll(False), self.tap_link,
               lambda: self.history("back"), lambda: self.history("forward"), self.search]
        if self.a.plan == "shown":
            ops = [lambda: self.scroll(True), lambda: self.scroll(True), lambda: self.scroll(False), self.tap_link]
        while time.time() < end:
            try:
                if not self.on_tab():
                    # On the list (a step left the tab): go back to the shown tab first.
                    if self.current and self.current in self.rows:
                        self.switch(self.current)
                    else:
                        self.record(act="skip", why="not on a tab")
                        time.sleep(3)
                        continue
                random.choice(ops)()
            except Exception as error:  # a failed step is a result
                self.record(act="error", error=str(error)[:200])
            time.sleep(random.uniform(0.5, 2.0))

    def workspaces(self):
        try:
            r = self.rig.cmux("workspace", "list", json_out=True, check=False)
        except ValueError:
            return []
        if isinstance(r, dict):
            r = r.get("value", r.get("workspaces", []))
            if isinstance(r, dict):
                r = r.get("workspaces", [])
        return [w for w in r if isinstance(w, dict)] if isinstance(r, list) else []

    def list_rows(self):
        """Workspace rows on the list (Buttons inside the list's frame)."""
        els = self.sim.tree()
        lst = [e for e in els if e.ident == "workspaces.list"]
        y0, y1 = (lst[0].frame[1], lst[0].frame[1] + lst[0].frame[3]) if lst else (100, 800)
        return [e for e in els if e.kind == "Button" and e.label and y0 <= e.center[1] <= y1
                and e.ident not in ("workspaces.new",)]

    def on_tab(self):
        els = self.sim.tree()
        return not any(e.ident == "workspaces.list" for e in els)

    def open_tab(self, name, url):
        before = {w.get("id") for w in self.workspaces()}
        t = time.time()
        try:
            self.to_list()
            rows_before = {e.ident or e.label for e in self.list_rows()}
        except Exception as error:
            return self.record(act="open", name=name, url=url, error=f"list: {str(error)[:150]}")
        self.current = name
        try:
            tv.TV.open_browser(self.tv, url)
        except Exception as error:
            return self.record(act="open", name=name, url=url, error=str(error)[:200])
        dt, _ = self.tv.wait_page(r"\w{4,}", 40)
        key = getattr(self, "last_open_key", None)
        self.tab_keys[name] = key
        renamed = None
        if True:
            for w in self.workspaces():
                if w.get("id") not in before:
                    r = self.rig.cmux("workspace", w["id"], "rename", "--name", f"brfz-{name}", check=False)
                    renamed = w["id"] if getattr(r, "returncode", 1) == 0 else f"rename failed: {(r.stderr or '')[:80]}"
        self.sim.shot(f"open-{name}")
        load_s = round(time.time() - t, 1)
        # The new row on the phone's list (its label is the page's, not the Mac's name):
        # remember its id to come back to this tab, then return to it.
        row_id = None
        if self.a.plan == "shown":
            # One tab for the whole run: stay on it (the list round trip below goes through the
            # page toolbar, whose Back is the page's history and leaves a blank start page).
            return self.record(act="open", name=name, url=url, load_s=load_s, key=key, mac_ws=renamed)
        try:
            self.to_list()
            new = [e for e in self.list_rows() if (e.ident or e.label) not in rows_before]
            if new:
                row_id = new[0].ident or new[0].label
                self.rows[name] = row_id
                self.sim.tap_el(new[0])
                time.sleep(1.5)
        except Exception as error:
            self.record(act="open-row", name=name, error=str(error)[:150])
        return self.record(act="open", name=name, url=url, load_s=load_s, key=key, mac_ws=renamed, row=row_id)

    def to_list(self):
        """journey.back_to_list, with an edge swipe and one more try (a streamed page can
        take the touches the toolbar's back control needs)."""
        # A scrolled page collapses its toolbar to the address pill ("Show toolbar, HOST"):
        # the back control is there only after the pill brings the toolbar back.
        pill = [e for e in self.sim.find(kind="Button") if (e.label or "").startswith("Show toolbar") and 0 <= e.center[1] <= 874]
        if pill:
            self.sim.tap_el(pill[-1])
            time.sleep(1.0)
        try:
            return self.j.back_to_list()
        except Exception as error:
            labels = [(e.kind, e.label, e.ident) for e in self.sim.tree() if e.label][:40]
            self.record(act="to-list-retry", error=str(error)[:80], labels=labels)
            self.sim.shot(f"to-list-{utc().replace(':', '')}")
            for _ in range(2):
                self.sim.drag(2, 450, 340, 450, 0.5, 30, 0.1)
                time.sleep(1.2)
            return self.j.back_to_list()

    def switch(self, name):
        t = time.time()
        self.to_list()
        want = self.rows.get(name)
        row = None
        for e in self.list_rows():
            if want and (e.ident == want or e.label == want):
                row = e
        if not row:
            return self.record(act="switch", name=name, error="row not listed")
        self.sim.tap_el(row)
        self.current = name
        ok = self.sim.wait(contains="Address", kind="Button", timeout=20) or self.sim.wait(contains="Search or enter", timeout=5)
        time.sleep(1.0)
        self.sim.shot(f"switch-{name}-{utc().replace(':', '')}")
        return self.record(act="switch", name=name, s=round(time.time() - t, 1), page=bool(ok))

    def list_idle(self, seconds):
        self.to_list()
        prev, self.current = self.current, None
        self.record(act="list-idle", seconds=seconds, left=prev)
        time.sleep(seconds)

    def idle(self, seconds):
        self.record(act="idle", seconds=seconds)
        time.sleep(seconds)

    def background(self, seconds):
        self.record(act="background", seconds=seconds)
        self.sim.home()
        time.sleep(seconds)
        e = dict(os.environ, **{"SIMCTL_CHILD_" + k: v for k, v in self.env.items()})
        subprocess.run(["xcrun", "simctl", "launch", self.udid, self.a.bundle], capture_output=True, env=e)
        time.sleep(2)
        self.sim.shot(f"after-bg-{utc().replace(':', '')}")

    # ---- the run ---------------------------------------------------------------
    def plan(self):
        a = self.a
        u = a.url
        if a.plan == "shown":
            # One tab shown and streaming the whole run: scroll/tap stretches between still
            # stretches of 70 s (each spans at least one 40 s media kill).
            p = [("open_tab", "A", u[0])]
            for _ in range(6):
                p += [("interact", 35), ("still_idle", 70)]
            return p
        p = [("open_tab", "A", u[0]), ("interact", 70), ("long_scroll", 12), ("interact", 60),
             ("open_tab", "B", u[1]), ("interact", 60),
             # No tab shown for > 30 s: the WebRTC media session lingers out; the next shown
             # tab brings it back and the lane switches route at a keyframe.
             ("list_idle", 45), ("switch", "B"), ("interact", 80),
             ("switch", "A"), ("interact", 50),
             ("open_tab", "C", u[2]), ("interact", 50)]
        if a.bg:
            p += [("background", a.bg), ("interact", 30)]
        p += [("still_idle", 125), ("switch", "B"), ("interact", 35), ("switch", "A"), ("interact", 35),
              ("switch", "C"), ("interact", 35), ("list_idle", 40), ("switch", "C"), ("interact", 60),
              ("switch", "B"), ("interact", 60)]
        return p

    def main(self):
        a = self.a
        if a.prepare_phone:
            return self.prepare_phone()
        self.rig = ls.Rig(a.rig)
        self.rig.device = self.rig.rig("device-id").stdout.strip()
        self.rig.seed()
        ws = self.workspaces()
        self.log(f"rig {self.rig.host}: device {self.rig.device}, workspace {self.rig.workspace} "
                 f"({len(ws)} workspaces: {[w.get('name') or w.get('title') for w in ws][:8]})")
        drop_file = f"$(cd {self.rig.dir} && python3 -c 'import rig; print(rig.mac().hostd_state)')/video-drop-permille"
        if a.drop_permille:
            self.rig.ssh(f"echo {int(a.drop_permille)} > {drop_file}")
        else:
            self.rig.ssh(f"rm -f {drop_file}")
        self.udid = ls.ensure_sim(a.sim, a.runtime, a.reuse)
        self.sim = Sim(self.udid, shots_dir=os.path.join(self.out, "shots"))
        for sub in ("dev.cmux.mobile", "dev.cmux"):
            subprocess.run(["xcrun", "simctl", "spawn", self.udid, "log", "config", "--subsystem", sub, "--mode",
                            "level:debug,persist:debug"], capture_output=True)
        self.imgsig = os.path.expanduser("~/cmux-next-ios-e2e/bin/brfz-imgsig")
        src = os.path.join(HERE, "imgsig.swift")
        if not os.path.exists(self.imgsig) or os.path.getmtime(self.imgsig) < os.path.getmtime(src):
            sh("xcrun", "swiftc", "-O", "-o", self.imgsig, src, timeout=300)
        self.j = Journey(self.sim, self.rig, self.out, a.app, self.log)
        self.tv = tv.TV.__new__(tv.TV)
        self.tv.j, self.tv.sim = self.j, self.sim
        self.env = {"CMUX_MOBILE_LOG": a.phone_log}
        if a.config == "relay":
            self.env["CMUX_MOBILE_DEV_RELAY_ONLY"] = "1"
        if a.config == "wgonly":
            self.env["CMUX_MOBILE_DEV_NO_WEBRTC_MEDIA"] = "1"
        for kv in a.env:
            k, _, v = kv.partition("=")
            self.env[k] = v
        phone_log = os.path.join(self.out, "phone-stderr.log")

        def launch():
            e = dict(os.environ, **{"SIMCTL_CHILD_" + k: v for k, v in self.env.items()})
            subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", f"--stderr={phone_log}.{int(time.time())}",
                            self.udid, a.bundle], check=True, capture_output=True, env=e)

        pairs = dict(l.strip().split("=", 1) for l in open(os.path.expanduser(a.creds)) if "=" in l)
        if not a.reuse:
            sh("xcrun", "simctl", "terminate", self.udid, a.bundle, check=False)
            subprocess.run(["xcrun", "simctl", "uninstall", self.udid, a.bundle], capture_output=True)
            subprocess.run(["xcrun", "simctl", "keychain", self.udid, "reset"], capture_output=True)
            sh("xcrun", "simctl", "install", self.udid, a.app)
        elif a.install:
            sh("xcrun", "simctl", "install", self.udid, a.app)  # same bundle: keeps the signed-in data
        self.env.update(CMUX_MOBILE_STACK_EMAIL=pairs["EMAIL"], CMUX_MOBILE_STACK_PASSWORD=pairs["PASSWORD"])
        self.start_oslog()
        launch()
        if not a.reuse:
            ls.onboard(self.sim, self.log)
        self.env.pop("CMUX_MOBILE_STACK_EMAIL")  # relaunches (background) need no password
        self.env.pop("CMUX_MOBILE_STACK_PASSWORD")
        self.t0 = time.time()
        self.start_host_monitor()
        self.log(f"app launched, config {a.config}, env {sorted(self.env)}, drop {a.drop_permille}, bg {a.bg}")
        # The link: open the rig's terminal workspace first (the Mac is listed and linked).
        self.j.back_to_list()
        row = self.sim.wait(prefix=self.rig.workspace, kind="Button", timeout=90)
        check(row, f"{self.rig.workspace} ({self.rig.host}) not listed on the phone")
        self.sim.tap_el(row)
        self.sim.wait(ident="terminal.composer.field", timeout=40)
        self.sim.shot("terminal-open")
        for step in self.plan():
            if a.minutes and time.time() - self.t0 > a.minutes * 60:
                self.log("minutes reached; ending the plan")
                break
            op, args = step[0], step[1:]
            self.log(f"step {op} {args} at +{(time.time() - self.t0) / 60:.1f} min")
            try:
                getattr(self, op)(*args)
            except Exception as error:
                self.record(act=f"{op}-failed", error=str(error)[:200])
        self.sim.shot("end")
        time.sleep(6)  # one more host report
        self.stop.set()
        self._host_poll()
        self.summarize()

    def prepare_phone(self):
        """Fresh simulator, the app installed and signed in, on the tab bar (later runs --reuse)."""
        a = self.a
        self.udid = ls.ensure_sim(a.sim, a.runtime, False)
        self.sim = Sim(self.udid, shots_dir=os.path.join(self.out, "shots"))
        pairs = dict(l.strip().split("=", 1) for l in open(os.path.expanduser(a.creds)) if "=" in l)
        subprocess.run(["xcrun", "simctl", "keychain", self.udid, "reset"], capture_output=True)
        sh("xcrun", "simctl", "install", self.udid, a.app)
        env = {"CMUX_MOBILE_LOG": a.phone_log, "CMUX_MOBILE_STACK_EMAIL": pairs["EMAIL"], "CMUX_MOBILE_STACK_PASSWORD": pairs["PASSWORD"]}
        e = dict(os.environ, **{"SIMCTL_CHILD_" + k: v for k, v in env.items()})
        subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", self.udid, a.bundle],
                       check=True, capture_output=True, env=e)
        ls.onboard(self.sim, self.log)
        self.sim.shot("prepared")
        self.log(f"phone prepared: {a.sim} {self.udid}")

    def summarize(self):
        acts = [json.loads(l) for l in open(os.path.join(self.out, "actions.jsonl"))]
        minutes = {}

        def slot(t):
            return int((t - self.t0) // 60)
        for t, tab, fps, carrier in self.fps_lines:
            m = minutes.setdefault(slot(t), {"frames": 0, "fps": [], "carriers": set()})
            m["frames"] += 30
            m["fps"].append(fps)
            m["carriers"].add(carrier)
        for (t0, k0), (t1, k1) in zip(self.kf, self.kf[1:]):
            m = minutes.setdefault(slot(t1), {"frames": 0, "fps": [], "carriers": set()})
            m["kf"] = m.get("kf", 0) + max(0, k1 - k0)
        for x in acts:
            if x.get("rtt") is not None or x.get("act") in ("scroll-down", "scroll-up", "tap", "back", "forward", "search"):
                m = minutes.setdefault(slot(x["t"]), {"frames": 0, "fps": [], "carriers": set()})
                m.setdefault("rtt", []).append(x.get("rtt"))
        table = []
        for k in sorted(minutes):
            m = minutes[k]
            rtts = [r for r in m.get("rtt", []) if r is not None]
            table.append({"minute": k, "decoded_frames": m["frames"], "fps_max": max(m["fps"], default=0),
                          "carriers": sorted(m["carriers"]), "kf_requests": m.get("kf", 0),
                          "inputs": len(m.get("rtt", [])), "no_response": len(m.get("rtt", [])) - len(rtts),
                          "rtt_median_s": sorted(rtts)[len(rtts) // 2] if rtts else None})
        phone = self.phone_stderr()
        res = {"args": {k: v for k, v in vars(self.a).items() if k != "creds"}, "t0": utc(self.t0),
               "minutes": round((time.time() - self.t0) / 60, 1), "tabs": self.tab_keys, "freezes": self.freezes,
               "per_minute": table, "host_events": self.host_events, "decode_failed": self.decode_failed,
               "phone_media_lines": [l[:300] for l in phone.splitlines()
                                     if re.search(r"keyframe|PLI|gate|media|lane|route|decode", l, re.I)][-300:]}
        json.dump(res, open(os.path.join(self.out, "results.json"), "w"), indent=2, default=list)
        self.log("per minute: " + json.dumps(table, default=list))
        self.log(f"done: freezes {len(self.freezes)}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--sim", required=True)
    ap.add_argument("--runtime", default="com.apple.CoreSimulator.SimRuntime.iOS-26-5")
    ap.add_argument("--rig", help="HOST:RIGDIR:WORKSPACE")
    ap.add_argument("--prepare-phone", action="store_true", help="only make the signed-in simulator (no rig)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--creds", required=True, help="EMAIL=/PASSWORD= file (0600) of the production test account")
    ap.add_argument("--bundle", default="dev.cmux.app.internal")
    ap.add_argument("--reuse", action="store_true", help="keep the signed-in simulator of a previous run")
    ap.add_argument("--install", action="store_true", help="with --reuse: install --app over the signed-in app")
    ap.add_argument("--config", default="default", choices=["default", "wgonly", "relay", "loss"])
    ap.add_argument("--drop-permille", type=int, default=0, help="the Mac drops this many of 1000 video RTP packets")
    ap.add_argument("--bg", type=float, default=0, help="background the app this many seconds mid-run")
    ap.add_argument("--url", nargs=3, default=["https://en.wikipedia.org/wiki/Cat", "https://news.ycombinator.com",
                                               "https://duckduckgo.com"])
    ap.add_argument("--env", action="append", default=[], help="K=V launch variable for the phone app (repeatable)")
    ap.add_argument("--plan", default="tabs", choices=["tabs", "shown"],
                    help="tabs: three tabs, switches, list idles; shown: one tab shown the whole run, still stretches")
    ap.add_argument("--minutes", type=float, default=0, help="stop the plan after this many minutes (0: whole plan)")
    ap.add_argument("--phone-log", default="info,cmux_mobile_link=debug,cmux_mobile_link_ffi=debug")
    ap.add_argument("--page-y0", type=float, default=130)
    ap.add_argument("--page-y1", type=float, default=740)
    ap.add_argument("--change-threshold", type=float, default=1.5)
    a = ap.parse_args()
    if a.config == "loss" and not a.drop_permille:
        a.drop_permille = 30
    Run(a).main()


if __name__ == "__main__":
    try:
        main()
    except Fail as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
