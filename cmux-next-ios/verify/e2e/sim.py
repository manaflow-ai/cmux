"""Headless simulator driving for the e2e rig: AX tree queries and real HID
touches through AXe, typing on the software keyboard (taps on its keys, never
`axe type`, which makes iOS assume a hardware keyboard), screenshots and video.
"""
import json
import os
import subprocess
import time

os.environ.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")


def sh(*args, check=True, timeout=120, capture=True):
    r = subprocess.run(list(args), capture_output=capture, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise RuntimeError(f"{args[0]} {' '.join(args[1:3])} failed: {(r.stderr or r.stdout or '').strip()[:400]}")
    return r.stdout if capture else ""


class Element(dict):
    @property
    def label(self): return self.get("AXLabel")
    @property
    def ident(self): return self.get("AXUniqueId")
    @property
    def value(self): return self.get("AXValue")
    @property
    def kind(self): return self.get("type")
    @property
    def center(self):
        f = self.get("frame") or {}
        return (f.get("x", 0) + f.get("width", 0) / 2, f.get("y", 0) + f.get("height", 0) / 2)
    @property
    def frame(self):
        f = self.get("frame") or {}
        return (f.get("x", 0), f.get("y", 0), f.get("width", 0), f.get("height", 0))
    def __repr__(self):
        return f"<{self.kind} {self.label!r} id={self.ident} v={self.value!r} {self.frame}>"


class Sim:
    def __init__(self, udid, shots_dir=None):
        self.udid = udid
        self.shots_dir = shots_dir
        self._video = None

    # ---- accessibility -------------------------------------------------
    def tree(self):
        try:
            raw = json.loads(sh("axe", "describe-ui", "--udid", self.udid, timeout=60))
        except (subprocess.TimeoutExpired, RuntimeError, ValueError):
            return [Element({"type": "Application", "frame": {}})]
        out = []
        def walk(n):
            out.append(Element(n))
            for c in n.get("children") or []:
                walk(c)
        for n in raw if isinstance(raw, list) else [raw]:
            walk(n)
        return out

    def find(self, label=None, ident=None, kind=None, contains=None, value=None, elements=None, suffix=None, prefix=None):
        res = []
        for e in elements if elements is not None else self.tree():
            if label is not None and e.label != label: continue
            if suffix is not None and not (e.label or "").endswith(suffix): continue
            if prefix is not None and not ((e.label or "") == prefix or (e.label or "").startswith(prefix + ",")): continue
            if ident is not None and not (e.ident == ident or (ident.endswith("*") and (e.ident or "").startswith(ident[:-1]))): continue
            if kind is not None and e.kind != kind: continue
            if value is not None and e.value != value: continue
            if contains is not None and contains.lower() not in " ".join(str(x) for x in (e.label, e.value, e.ident) if x).lower(): continue
            f = e.frame
            if f[2] <= 0 or f[3] <= 0: continue
            res.append(e)
        return res

    def wait(self, timeout=20.0, interval=0.3, **query):
        """First element matching `query`, polling the AX tree; None on timeout."""
        deadline = time.monotonic() + timeout
        while True:
            found = self.find(**query)
            if found:
                return found[0]
            if time.monotonic() > deadline:
                return None
            time.sleep(interval)

    def wait_any(self, queries, timeout=20.0, interval=0.3):
        """(index, element) of the first of several queries to match."""
        deadline = time.monotonic() + timeout
        while True:
            els = self.tree()
            for i, q in enumerate(queries):
                f = self.find(elements=els, **q)
                if f:
                    return i, f[0]
            if time.monotonic() > deadline:
                return None, None
            time.sleep(interval)

    def texts(self):
        return [str(t) for e in self.tree() for t in (e.label, e.value) if t]

    # ---- touches ---------------------------------------------------------
    def tap(self, x, y):
        t = time.time()
        # --tap-style simulator: the default (automatic) asks accessibility what is
        # under the point first, and that query hung for minutes on the rig (round 6).
        sh("axe", "tap", "--udid", self.udid, "-x", f"{x:.1f}", "-y", f"{y:.1f}", "--tap-style", "simulator", timeout=25)
        return t

    def press(self, x, y, hold=0.08):
        """Touch down, short hold, up: SwiftUI menus and pickers open only on this."""
        t = time.time()
        sh("axe", "touch", "--udid", self.udid, "-x", f"{x:.1f}", "-y", f"{y:.1f}", "--down", "--up", "--delay", str(hold))
        return t

    def tap_el(self, e):
        x, y = e.center
        fx, fy, fw, fh = e.frame
        # Clip the frame to the screen and tap the middle of what is visible.
        vx0, vx1 = max(fx, 0), min(fx + fw, 402)
        vy0, vy1 = max(fy, 0), min(fy + fh, 874)
        if vx1 > vx0 and vy1 > vy0:
            x, y = (vx0 + vx1) / 2, (vy0 + vy1) / 2
        if not (0 <= x <= 402 and 0 <= y <= 874):
            raise LookupError(f"off screen: {e!r}")
        return self.tap(x, y)

    def reveal_h(self, query, tries=12, lane=(20, 382)):
        """Drags a horizontal strip until the element matching `query` is fully visible."""
        for _ in range(tries):
            found = self.find(**query)
            if not found:
                time.sleep(0.5)
                continue
            e = found[0]
            x, y, w, h = e.frame
            lo, hi = lane
            if x >= lo - 8 and x + w <= hi + 8:
                return e
            span = (hi - lo) * 0.8
            mid = (lo + hi) / 2
            dx = max(-span, min(span, (x + w / 2) - mid))
            if dx > 0:   # content moves left: drag right-to-left
                self.drag(hi - 10, y + h / 2, hi - 10 - dx, y + h / 2)
            else:        # content moves right: start well inside, away from the drawer edge
                self.drag(max(lo + 10, 150 if lo < 60 else lo + 10), y + h / 2, max(lo + 10, 150 if lo < 60 else lo + 10) - dx, y + h / 2)
            time.sleep(0.3)
            self.close_drawer()
        return None

    def close_drawer(self):
        """Closes the team drawer if a drag opened it."""
        if self.find(label="Close teams"):
            self.drag(380, 500, 60, 500, 0.4, 20, 0.1)
            time.sleep(0.8)
            return True
        return False

    def tap_q(self, timeout=15.0, **query):
        e = self.wait(timeout=timeout, **query)
        if e is None:
            raise LookupError(f"not found: {query}")
        return self.tap_el(e)

    def long_press(self, x, y, seconds=1.0):
        sh("axe", "touch", "--udid", self.udid, "-x", f"{x:.1f}", "-y", f"{y:.1f}", "--down", "--up", "--delay", str(seconds))

    def drag(self, x1, y1, x2, y2, duration=1.0, steps=60, hold=0.4):
        """Point-to-point drag with a still hold at the end, so no fling momentum."""
        sh("axe", "drag", "--udid", self.udid, "--start-x", f"{x1:.0f}", "--start-y", f"{y1:.0f}",
           "--end-x", f"{x2:.0f}", "--end-y", f"{y2:.0f}", "--duration", str(duration), "--steps", str(steps),
           "--post-delay", str(hold))

    def swipe(self, x1, y1, x2, y2, duration=0.4):
        sh("axe", "swipe", "--udid", self.udid, "--start-x", str(x1), "--start-y", str(y1),
           "--end-x", str(x2), "--end-y", str(y2), "--duration", str(duration))

    # ---- software keyboard ----------------------------------------------
    SHIFTED = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    def keyboard(self, els=None):
        """Software keyboard keys by label (only keys inside the keyboard's layout view)."""
        els = els if els is not None else self.tree()
        star = [e for e in els if (e.ident or "").startswith("UIKeyboardLayoutStar")]
        top = min((e.frame[1] for e in star), default=None)
        keys = {}
        if top is None:
            return keys
        for e in els:
            x, y, w, h = e.frame
            if e.kind == "Button" and e.label is not None and w > 0 and h > 0 and y >= top - 2 and y < 820:
                keys.setdefault(e.label, e)
        return keys

    def dismiss_keyboard_intro(self):
        els = self.tree()
        if any(e.ident == "UIContinuousPathIntroductionView" for e in els):
            c = self.find(label="Continue", kind="Button", elements=els)
            if c:
                self.tap_el(c[-1])
                time.sleep(0.6)

    def softtype(self, text):
        """Types `text` by tapping software keyboard keys, switching layouts as needed."""
        self.dismiss_keyboard_intro()
        keys = self.keyboard()
        if not keys:
            # A hardware keyboard event (axe) hides the soft keyboard: type the same way.
            sh("axe", "type", text, "--udid", self.udid, check=False)
            return
        for ch in text:
            label = {" ": " ", "\n": "return"}.get(ch, ch)
            want = label.lower() if ch in self.SHIFTED else label
            if want not in keys and ch == "\n":
                for alt in ("continue", "Return", "return", "go", "send", "Send", "done", "Done", "search"):
                    if alt in keys: want = alt; break
            if want not in keys:
                for switch in ("numbers", "more", "letters", "symbols", "more, numbers", "more, letters"):
                    if switch in keys:
                        self.tap_el(keys[switch]); time.sleep(0.25)
                        keys = self.keyboard()
                        if want in keys: break
                if want not in keys:
                    for switch in ("symbols", "numbers", "letters"):
                        if switch in keys:
                            self.tap_el(keys[switch]); time.sleep(0.25)
                            keys = self.keyboard()
                            if want in keys: break
            if want not in keys:
                # A loaded Mac can lag the layout switch (or a keyboard intro was still up):
                # dismiss the intro, give the switch time to land, and try once more.
                self.dismiss_keyboard_intro()
                for switch in ("numbers", "more", "more, numbers"):
                    keys = self.keyboard()
                    if want in keys: break
                    if switch in keys:
                        self.tap_el(keys[switch]); time.sleep(1.0)
                        keys = self.keyboard()
                        if want in keys: break
            if want not in keys:
                raise LookupError(f"no soft key for {ch!r}; have {sorted(keys)[:40]}")
            if ch in self.SHIFTED and "shift" in keys:
                self.tap_el(keys["shift"]); time.sleep(0.12)
            self.tap_el(keys[want])
            time.sleep(0.05)
            if not ch.isalpha() and ch not in " \n":
                # Most layouts flip back to letters after a symbol + space; refresh lazily.
                pass
            if ch in (" ", "\n") or not ch.isalnum():
                keys = self.keyboard()

    # ---- OCR (system sheets and pickers that the AX tree does not show) ---
    def ocr(self):
        """[(x, y, w, h, text)] in points, read with Vision from a fresh screenshot."""
        here = os.path.dirname(os.path.abspath(__file__))
        binp = os.path.expanduser("~/cmux-next-ios-e2e/bin/ocr")
        src = os.path.join(here, "ocr.swift")
        if not os.path.exists(binp) or os.path.getmtime(binp) < os.path.getmtime(src):
            os.makedirs(os.path.dirname(binp), exist_ok=True)
            sh("xcrun", "swiftc", "-O", "-o", binp, src, timeout=300)
        tmp = f"/tmp/cmux-mobile-e2e-ocr-{self.udid}.png"
        sh("xcrun", "simctl", "io", self.udid, "screenshot", tmp)
        out = []
        for line in sh(binp, tmp).splitlines():
            box, _, text = line.partition("\t")
            x, y, w, h = (float(v) for v in box.split())
            out.append((x, y, w, h, text))
        return out

    def ocr_find(self, needle, timeout=0.0):
        deadline = time.monotonic() + timeout
        while True:
            hits = [o for o in self.ocr() if needle.lower() in o[4].lower()]
            if hits or time.monotonic() >= deadline:
                return hits
            time.sleep(0.5)

    # ---- capture ---------------------------------------------------------
    def shot(self, name):
        if not self.shots_dir:
            return None
        os.makedirs(self.shots_dir, exist_ok=True)
        path = os.path.join(self.shots_dir, f"{name}.png")
        try:
            sh("xcrun", "simctl", "io", self.udid, "screenshot", path, check=False, timeout=45)
        except subprocess.TimeoutExpired:
            return None
        return path if os.path.exists(path) else None

    def record_start(self, path):
        self.record_stop()
        self._video = (subprocess.Popen(["xcrun", "simctl", "io", self.udid, "recordVideo", "--codec", "h264", "--force", path],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True), path)
        # recordVideo prints "Recording started" on stderr once frames flow.
        import select
        t0 = time.monotonic()
        buf = ""
        while time.monotonic() - t0 < 10:
            r, _, _ = select.select([self._video[0].stderr], [], [], 0.5)
            if r:
                chunk = os.read(self._video[0].stderr.fileno(), 4096).decode(errors="replace")
                if not chunk:
                    break
                buf += chunk
                if "Recording started" in buf:
                    break
        if "Recording started" not in buf:
            # e.g. "Host recording is already in progress" after a killed recorder:
            # a metric without video would report n=0 silently.
            self.record_stop()
            raise RuntimeError(f"screen recording did not start: {buf.strip()[-200:]}")
        return time.time()

    def record_stop(self):
        if not self._video:
            return None
        proc, path = self._video
        proc.send_signal(2)
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill()
        self._video = None
        return path

    # ---- app lifecycle ---------------------------------------------------
    def launch(self, bundle, args=(), env=None, terminate=True):
        e = dict(os.environ)
        for k, v in (env or {}).items():
            e["SIMCTL_CHILD_" + k] = v
        flags = ["--terminate-running-process"] if terminate else []
        r = subprocess.run(["xcrun", "simctl", "launch", *flags, self.udid, bundle, *args],
                           capture_output=True, text=True, env=e)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip())
        return time.time()

    def terminate(self, bundle):
        sh("xcrun", "simctl", "terminate", self.udid, bundle, check=False)

    def home(self):
        sh("axe", "button", "--udid", self.udid, "home", check=False)
