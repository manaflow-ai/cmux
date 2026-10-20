"""The production Mac -> phone journey, step by step, against the real rig.

Every step drives the phone with real HID touches (AXe) and the software
keyboard, checks the effect on the Mac through the tagged app's own CLI, and
records pass / fail / blocked with timings, notes and a screenshot.
"""
import json
import os
import random
import re
import subprocess
import time
import traceback

BUNDLE = "dev.cmux.mobile"


class Blocked(Exception):
    """The step cannot run in this rig (missing prerequisite); never a pass."""


class Fail(Exception):
    pass


def check(cond, msg):
    if not cond:
        raise Fail(msg)


class Journey:
    def __init__(self, sim, mac, out_dir, app_path, log):
        self.sim, self.mac, self.out, self.app_path, self.log = sim, mac, out_dir, app_path, log
        self.results = []
        self.run_id = time.strftime("%H%M%S")
        self.ws_name = f"e2e-{self.run_id}"
        self.seed = {}
        self.device_id = None
        self.ws_row_label = None
        self.grid_notes = []
        self.hangs = []

    # ------------------------------------------------------------------ runner
    def app_pid(self):
        r = subprocess.run(["pgrep", "-f", f"{self.sim.udid}/data/Containers/Bundle/Application/.*/CmuxMobileApp.app/CmuxMobileApp"],
                           capture_output=True, text=True)
        pids = r.stdout.split()
        return int(pids[0]) if pids else None

    def check_hang(self, where):
        """An empty AX tree with the app pegged at ~100% CPU is a main-thread hang: sample it,
        record it, relaunch. Returns the record or None."""
        if len(self.sim.tree()) > 1:
            return None
        pid = self.app_pid()
        if not pid:
            hang = {"where": where, "kind": "not running"}
        else:
            cpu = float(subprocess.run(["ps", "-o", "%cpu=", "-p", str(pid)], capture_output=True, text=True).stdout.strip() or 0)
            time.sleep(3)
            if len(self.sim.tree()) > 1:
                return None
            path = os.path.join(self.out, f"hang-{len(self.hangs)+1}-{where}.sample.txt")
            subprocess.run(["sample", str(pid), "3", "-file", path], capture_output=True)
            hang = {"where": where, "kind": "main thread busy, no accessibility", "cpu": cpu, "sample": os.path.basename(path)}
            self.sim.shot(f"hang-{len(self.hangs)+1}-{where}")
        self.hangs.append(hang)
        try:
            self.sim.launch(BUNDLE)
        except RuntimeError as err:
            # Not installed yet (a new simulator before fresh_install): nothing hung.
            self.hangs.pop()
            self.log(f"    app not launchable before {where} ({str(err)[:80]}); continuing")
            return None
        self.log(f"    HANG after {where}: {hang}; relaunching the app")
        time.sleep(4)
        return hang

    def step(self, sid, title, owner, fn):
        self.check_hang(f"before-{sid}")
        self.log(f"--- {sid}: {title}")
        t0 = time.time()
        rec = {"id": sid, "title": title, "owner": owner, "started": t0}
        try:
            notes = fn() or {}
            rec.update(status="pass", **({"notes": notes} if isinstance(notes, str) else notes))
        except Blocked as e:
            rec.update(status="blocked", notes=str(e))
        except Exception as e:  # any error is this step's failure; the journey goes on
            rec.update(status="fail", notes=str(e)[:600], trace=traceback.format_exc(limit=3)[-800:])
        rec["seconds"] = round(time.time() - t0, 2)
        rec["screenshot"] = self.sim.shot(f"{len(self.results)+1:02d}-{sid}")
        hang = self.check_hang(sid)
        if hang:
            rec["hang"] = hang
            if rec["status"] == "pass":
                rec["status"] = "fail"
            rec["notes"] = f"APP HUNG ({hang['kind']}, sample {hang.get('sample')}). " + str(rec.get("notes", ""))
        self.results.append(rec)
        self.log(f"    {rec['status'].upper()} ({rec['seconds']} s) {rec.get('notes', '')}")
        return rec["status"] == "pass"

    # ------------------------------------------------------------------ helpers
    def tab(self, name):
        """Selects a tab bar item; a scrolled page minimizes the iOS 26 tab bar, so scroll up first."""
        self.sim.close_drawer()
        for _ in range(4):
            e = self.sim.find(label=name, kind="RadioButton")
            if e:
                self.sim.tap_el(e[0]); time.sleep(0.8)
                return
            self.sim.drag(201, 250, 201, 750, 0.3, 20, 0.1); time.sleep(0.8)
        raise Fail(f"tab bar item {name!r} not found")

    def mac_screen(self, term):
        return self.mac.cmux("terminal", term, "screen", "read", json_out=True)

    def mac_wait_text(self, term, needle, timeout=15.0, count=1):
        deadline = time.time() + timeout
        text = ""
        while time.time() < deadline:
            text = self.mac_screen(term).get("text", "")
            if text.count(needle) >= count:
                return text
            time.sleep(0.25)
        raise Fail(f"Mac terminal never showed {needle!r} x{count}; last screen tail: {text[-200:]!r}")

    def mac_write(self, term, text):
        self.mac.cmux("terminal", term, "write", "--text", text)

    SYSTEM_DISMISS = ("Not Now", "Don’t Allow", "Don't Allow", "Cancel")

    def dismiss_system(self, els=None):
        els = els if els is not None else self.sim.tree()
        for label in self.SYSTEM_DISMISS:
            hit = [e for e in els if e.label == label and e.kind == "Button"]
            if hit and any(k in (x.label or "") for x in els for k in ("Dictation", "Allow", "Notifications", "would like")):
                self.sim.press(*hit[0].center); time.sleep(0.8)
                return True
        return False

    def back_to_list(self):
        """From anywhere: dismiss alerts, close the drawer and keyboard, pop to the Workspaces list."""
        tapped_back = kb_tries = sheet_try = 0
        for _ in range(16):
            els = self.sim.tree()
            if self.dismiss_system(els):
                continue
            if any(e.label == "Close teams" for e in els):
                self.sim.drag(380, 500, 60, 500, 0.4, 20, 0.1); time.sleep(0.8); continue
            if any(e.ident == "workspaces.list" for e in els) and any(e.label == "Workspaces" and e.kind == "RadioButton" for e in els):
                return
            grab = [e for e in els if e.label == "Sheet Grabber"]
            if grab:  # a sheet: its Done (or back inside it), else drag the grabber down
                gy = grab[0].frame[1]
                inner = [e for e in els if e.kind == "Button" and gy < e.frame[1] < gy + 80
                         and (e.label in ("Done", "Close", "Cancel") or e.ident == "BackButton")]
                done = [e for e in inner if e.label in ("Done", "Close", "Cancel")]
                if done or inner:
                    self.sim.tap_el((done or inner)[0]); time.sleep(1.0); continue
                self.sim.drag(201, gy + 10, 201, 870, 0.3, 20, 0.1); time.sleep(1.0); continue
            # On screen only: a hidden tab grid keeps its Done far below (y 2536).
            grid_done = [e for e in els if e.kind == "Button" and e.label == "Done" and 700 < e.frame[1] < 874]
            if grid_done:  # the tab grid
                self.sim.tap_el(grid_done[0]); time.sleep(1.0); continue
            if self.sim.keyboard(els) and kb_tries < 2:
                kb_tries += 1
                cancel = [e for e in els if e.kind == "Button" and e.label == "Cancel" and e.frame[0] >= 0]
                if cancel:  # a browser address field holds the keyboard
                    self.sim.tap_el(cancel[0]); time.sleep(1.0); continue
                self.hide_keyboard(); continue
            back = [e for e in els if e.kind == "Button" and (e.label == "Back" or e.ident == "BackButton") and e.frame[0] >= 0]
            if back and tapped_back >= 2:
                # The back control is hidden or ignored (e.g. a page whose address bar takes
                # the touch): the interactive edge swipe pops.
                self.sim.drag(2, 400, 320, 400, 0.5, 30, 0.1); time.sleep(1.2); tapped_back = 0; continue
            if back:
                tapped_back += 1
                self.sim.tap_el(back[0]); time.sleep(1.2); continue
            close = [e for e in els if e.kind == "Button" and e.label in ("Close", "Done", "Cancel") and e.frame[0] >= 0]
            if close:
                self.sim.tap_el(close[0]); time.sleep(1.0); continue
            tab = [e for e in els if e.label == "Workspaces" and e.kind == "RadioButton"]
            if tab:
                self.sim.tap_el(tab[0]); time.sleep(1.0); continue
            # A sheet the AX tree does not show (system pickers, Files and Links): swipe it down,
            # from the top of a full sheet or from a half sheet's grabber.
            y0 = 300 if sheet_try % 2 == 0 else 425
            sheet_try += 1
            self.sim.drag(201, y0, 201, 870, 0.3, 20, 0.1); time.sleep(1.0)
        raise Fail("could not get back to the Workspaces list")

    def open_seed_workspace(self):
        self.back_to_list()
        row = self.sim.wait(prefix=self.ws_name, kind="Button", timeout=30)
        check(row, f"workspace {self.ws_name} not in the phone's list")
        t = self.sim.tap_el(row)
        el = self.sim.wait(ident="terminal.composer.field", timeout=20)
        check(el, "terminal composer never appeared")
        return time.time() - t

    def focus_terminal(self):
        """Taps the terminal so its own input (direct typing) owns the soft keyboard."""
        comp = self.sim.wait(ident="terminal.composer.field", timeout=10)
        check(comp, "no terminal on screen")
        y = max(150, comp.frame[1] - 200)
        self.sim.tap(201, y)
        kb = self.sim.wait(label="q", kind="Button", timeout=6)
        if not kb:
            # A keyboard toggle exists on the key bar.
            k = self.sim.find(ident="terminal.keyboardToggle") or self.sim.find(label="Show Keyboard")
            if k:
                self.sim.tap_el(k[0])
                kb = self.sim.wait(label="q", kind="Button", timeout=6)
        check(kb, "software keyboard did not appear for direct typing")
        self.sim.dismiss_keyboard_intro()

    # Fixed at the key bar's leading edge (design/terminal B2): esc, ctrl and ^C.
    # Alt and the rest (tab, arrows, ^D ^Z ^L, symbols, paste) live in the
    # "More keys" scroller between them and the joystick / Hide Keyboard.
    PINNED_KEYS = ("Escape", "Control", "Control C")

    def keybar_scroller(self):
        """The "More keys" scroller's x range, read from its frame (fallback: the 402 pt layout)."""
        sc = [e for e in self.sim.find(label="More keys") if e.frame[2] > 40]
        if sc:
            x, _, w, _ = sc[0].frame
            return (x, x + w)
        return (178, 300)

    def keybar_lane(self, label):
        lo, hi = self.keybar_scroller()
        return (8, lo) if label in self.PINNED_KEYS else (lo, hi)

    def keybar_pinned(self, label):
        """A pinned key is always a visible button: no scrolling, find it and tap it."""
        lo, _ = self.keybar_scroller()
        hits = [e for e in self.sim.find(label=label, kind="Button") if e.frame[0] + e.frame[2] <= lo + 8]
        check(hits, f"key bar has no pinned {label!r} (expected left of the More keys scroller at x {lo:.0f})")
        return hits[0]

    # The key bar scroller's keys in order (CmuxMobileTerminal KeyBarKey.middle).
    SCROLLER_KEYS = ["Tab", "Shift Tab", "Up Arrow", "Down Arrow", "Left Arrow", "Right Arrow", "Control D", "Control Z",
                     "Control L", "Alt", "|", "~", "/", "-", "Paste", "`", "{", "}", "[", "]", "Control R", "Control B"]

    def keybar_reveal(self, label):
        if label in self.PINNED_KEYS:
            return self.keybar_pinned(label)
        lane = self.keybar_lane(label)
        # Keys scrolled out of the row are hidden from accessibility
        # (KeyBarClipping), so the rig cannot aim at one it does not see: page
        # the scroller forward, then back, until the key is listed.
        sc = [e for e in self.sim.find(label="More keys") if e.frame[2] > 40]
        y = sc[0].center[1] if sc else None
        # One key width (40 pt key + 6 pt gap) per drag, so the snapping row
        # never overshoots past the key, toward the key by the row's order (R1-6).
        step = 46
        for _ in range(len(self.SCROLLER_KEYS) + 2):
            if y is None or self.sim.find(label=label, kind="Button"):
                break
            shown = [e.label for e in self.sim.tree() if (e.ident or "").startswith("terminal.key.")
                     and e.label in self.SCROLLER_KEYS]
            if label in self.SCROLLER_KEYS and shown:
                direction = 1 if self.SCROLLER_KEYS.index(label) > self.SCROLLER_KEYS.index(shown[0]) else -1
            else:
                direction = 1
            lo, hi = lane
            start = (lo + hi) / 2 + direction * step / 2
            self.sim.drag(start, y, start - direction * step, y, duration=0.5, hold=0.3)
            time.sleep(0.4)
        e = self.sim.reveal_h(dict(label=label, kind="Button"), lane=lane, tries=30)
        check(e, f"key bar has no {label!r}")
        return e

    def keybar(self, label):
        # Pinned keys are tapped directly; the rest are scrolled into the lane first.
        return self.sim.tap_el(self.keybar_reveal(label))

    def hide_keyboard(self):
        """Hides the software keyboard (the key bar's button, else a drag down on the page)."""
        for _ in range(2):
            els = self.sim.tree()
            if not self.sim.keyboard(els):
                return
            e = self.sim.find(label="Hide Keyboard", elements=els)
            if e:
                self.sim.tap_el(e[0])
            else:
                self.sim.drag(201, 300, 201, 700, 0.3, 20, 0.1)
            time.sleep(0.8)

    # ------------------------------------------------------------------ setup
    def cleanup_mac(self):
        """Closes the rig's own e2e-* and phone-made workspaces from earlier runs."""
        for w in self.mac.cmux("workspace", "list", json_out=True) or []:
            if re.match(r"^(e2e-\d{6}|New Workspace( \d+)?)$", w.get("name") or ""):
                self.mac.cmux("workspace", w["id"], "close", check=False)

    def seed_mac(self):
        self.cleanup_mac()
        r = self.mac.cmux("workspace", "create", "--name", self.ws_name, json_out=True)["value"]
        t2 = self.mac.cmux("tab", "create", "terminal", "--workspace", r["workspace_id"], json_out=True)["value"]
        self.seed = {"ws": r["workspace_id"], "term1": r["terminal_id"], "tab1": r["tab_id"],
                     "term2": t2["terminal_id"], "tab2": t2["tab_id"]}
        self.mac.cmux("tab", r["tab_id"], "rename", "e2e-t1")
        self.mac.cmux("tab", t2["tab_id"], "rename", "e2e-t2")
        self.mac.cmux("tab", r["tab_id"], "focus", check=False)
        self.device_id = None
        for _ in range(60):
            self.device_id = self.mac.device_id()
            if self.device_id:
                break
            time.sleep(1)
        return self.seed

    def which_term(self, marker):
        for k in ("term1", "term2"):
            if marker in self.mac_screen(self.seed[k]).get("text", ""):
                return self.seed[k]
        return None

    # ================================================================== steps
    def s_fresh_install(self):
        self.sim.terminate(BUNDLE)
        subprocess.run(["xcrun", "simctl", "uninstall", self.sim.udid, BUNDLE], capture_output=True)
        # A new phone: the simulator keychain outlives an uninstall, as on a device.
        subprocess.run(["xcrun", "simctl", "keychain", self.sim.udid, "reset"], capture_output=True)
        subprocess.run(["xcrun", "simctl", "install", self.sim.udid, self.app_path], check=True, capture_output=True)
        t = self.sim.launch(BUNDLE)
        e = self.sim.wait(label="Continue with email", kind="Button", timeout=30)
        check(e, "Welcome never showed sign-in choices")
        texts = [x for x in self.sim.texts() if len(x) > 8][:6]
        return {"notes": f"Welcome in {time.time()-t:.1f} s: {texts[:3]}"}

    def s_sign_in(self):
        self.sim.tap_q(label="Continue with email", kind="Button")
        f = self.sim.wait(kind="TextField", timeout=10)
        check(f, "email field missing")
        self.sim.dismiss_keyboard_intro()
        self.sim.softtype("42")
        go = [e for e in self.sim.find(kind="Button") if e.label in ("Send code", "Continue") and e.frame[1] < 560]
        # With a hardware keyboard attached no software keyboard lifts the button.
        go = go or [e for e in self.sim.find(kind="Button") if e.label in ("Send code", "Continue")]
        check(go, "no Send code / Continue button on the email step")
        t = self.sim.tap_el(go[0])
        i, _ = self.sim.wait_any([dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"),
                                  dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=40)
        check(i is not None, "sign-in did not finish within 40 s")
        return {"notes": f"signed in with the DEBUG dev credential (email 42) in {time.time()-t:.1f} s",
                "metric_signin_s": round(time.time() - t, 2)}

    def s_choose_space(self):
        i, _ = self.sim.wait_any([dict(ident="setup.teams.create"), dict(ident="setup.teams.choose"),
                                  dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=20)
        notes = []
        if i in (0, 1):
            nn = self.sim.find(label="Not now", kind="Button")
            personal = self.sim.find(ident="setup.teams.personal")
            if personal:
                self.sim.tap_el(personal[0]); notes.append("space: Personal")
            elif nn:
                self.sim.tap_el(nn[0]); notes.append("team: Not now (personal space)")
            else:
                p = self.sim.find(contains="Personal", kind="Button")
                check(p, "no personal choice on the team step")
                self.sim.tap_el(p[0]); notes.append("team: Personal")
            i, _ = self.sim.wait_any([dict(contains="Connect your Mac"), dict(label="Workspaces", kind="RadioButton")], timeout=20)
        if i is not None and self.sim.find(contains="Connect your Mac"):
            st = self.sim.wait(ident="connect-mac.status", timeout=30)
            notes.append(f"connect step: {st.label if st else 'no status'}")
            # The page is still sliding in when its status shows; a tap then
            # can be dropped (the rig stalled here on a loaded Mac: Continue
            # never fired, then back_to_list swiped back to "Choose a space").
            # Wait for the button to settle, and tap again if the page stays.
            for attempt in range(3):
                # Tap only once the button stopped moving (the page slides in).
                prev, button = None, None
                for _ in range(20):
                    found = self.sim.find(label="Continue", kind="Button")
                    button = found[0] if found else None
                    if button and prev and button.frame == prev:
                        break
                    prev = button.frame if button else None
                    time.sleep(0.25)
                check(button, "no Continue button on the connect step")
                self.sim.tap_el(button)
                time.sleep(1.5)
                if not self.sim.find(contains="Connect your Mac"):
                    break
                notes.append(f"Continue tap {attempt + 1} did not advance")
        if self.sim.find(label="Turn on notifications"):
            self.sim.tap_q(label="Not now", kind="Button"); notes.append("notifications: Not now")
        check(self.sim.wait(label="Workspaces", kind="RadioButton", timeout=20), "never reached the tab bar")
        return "; ".join(notes)

    def s_mac_discovered(self):
        self.tab("Workspaces")
        check(self.device_id, "the rig Mac has no cmux-mobile-host device id (Allow iPhone Connections off?)")
        if self.sim.wait(ident="workspaces.filter", timeout=8) and not self.sim.find(ident="workspaces.chip.*"):
            return self.mac_discovered_filter()
        lies, t0 = [], time.time()
        chip = None
        while time.time() - t0 < 45:
            els = self.sim.tree()
            for e in els:
                if (e.ident or "").startswith("workspaces.empty") or "No workspaces" in (e.label or ""):
                    lies.append(f"{e.label or e.ident}@{time.time()-t0:.1f}s")
            if self.sim.find(ident=f"workspaces.chip.{self.device_id}", elements=els):
                chip = self.sim.reveal_h(dict(ident=f"workspaces.chip.{self.device_id}"))
                if chip:
                    break
            time.sleep(0.5)
        check(chip, f"rig Mac (device {self.device_id}) never listed on the phone in 45 s")
        t = self.sim.tap_el(chip)
        st = self.watch_link(t, 12, lies)
        fallback = None
        if st is None:
            # The chip only filters; the link stays on another online Mac. The chip's
            # context menu (long press) has Reconnect, which retargets the link.
            fallback = "chip tap left the link on another Mac; used long-press > Reconnect"
            chip = self.sim.reveal_h(dict(ident=f"workspaces.chip.{self.device_id}"))
            self.sim.long_press(*chip.center, seconds=1.0)
            time.sleep(1.2)
            t2 = self.sim.tap_q(label="Reconnect", timeout=5)
            st = self.watch_link(t2, 30, [])
        check(st, "link never reached Connected for the rig Mac")
        self.linked_s = time.time() - t
        check(not lies and not fallback, f"selecting the online rig Mac ({chip.label}) showed "
              f"{sorted(set(l.split('@')[0] for l in lies))[:2]} at {[l.split('@')[1] for l in lies][:3]}; "
              f"{fallback or ''}; the list filter does not retarget the link (WorkspacesList.select -> MacFilter only; "
              f"LiveCoordinator.select is reached only from Reconnect)")
        return {"notes": f"{chip.label} [{chip.value}] -> '{st}' in {time.time()-t:.1f} s"}

    def lie_scan(self, els, t, lies):
        for e in els:
            if (e.ident or "").startswith("workspaces.empty") or "No workspaces" in (e.label or ""):
                lies.append(f"{e.label or e.ident}@{time.time()-t:.1f}s")

    def mac_discovered_filter(self):
        lies, t0 = [], time.time()
        for _ in range(4):
            self.lie_scan(self.sim.tree(), t0, lies)
        t = self.choose_mac()
        rows = None
        while time.time() - t < 30:
            els = self.sim.tree()
            self.lie_scan(els, t, lies)
            if self.sim.find(prefix=self.ws_name, kind="Button", elements=els):
                rows = time.time() - t
                break
            time.sleep(0.3)
        check(rows is not None, f"the rig Mac's workspaces never listed within 30 s of choosing it; lies {lies[:3]}")
        st = self.link_status()
        dt = self.wait_connected(30) if "Connected" not in st else 0.0
        st = st if "Connected" in st else self.link_status()
        check(dt is not None, f"rows shown, but the link never reached Connected ({st!r})")
        check(not lies, f"empty state shown while the Mac was online: {sorted(set(l.split('@')[0] for l in lies))[:2]} "
                        f"at {[l.split('@')[1] for l in lies][:4]}")
        return {"notes": f"Filter > rig Mac: rows in {rows:.1f} s; link '{st}'"}

    def watch_link(self, t, timeout, lies):
        while time.time() - t < timeout:
            els = self.sim.tree()
            for e in els:
                if (e.ident or "").startswith("workspaces.empty") or "No workspaces" in (e.label or ""):
                    lies.append(f"{e.label or e.ident}@{time.time()-t:.1f}s")
            s = self.sim.find(ident="mac-link-status", elements=els)
            if s and "Connected" in (s[0].label or "") and self.sim.find(ident="workspace.row.*", elements=els):
                return s[0].label
            time.sleep(0.3)
        return None

    def s_workspace_list(self):
        self.back_to_list()
        rows = self.mac.cmux("workspace", "list", json_out=True) or []
        # The Mac's home workspace (`kind` "home") is never a phone Workspaces row:
        # the phone has its own Home tab (CmuxMobileLive `DaemonTree`, `homeWorkspaces`).
        # Matched by kind like the phone, never by name: a workspace named "Home"
        # is still a row.
        mac = [w["name"] for w in rows if w.get("kind") != "home"]
        has_kind = any("kind" in w for w in rows)
        deadline = time.time() + 20
        phone = []
        while time.time() < deadline:
            phone = sorted({(e.label or "").split(",")[0] for e in self.sim.find(ident="workspace.row.*", kind="Button")})
            if self.ws_name in phone:
                break
            time.sleep(0.5)
        missing = [n for n in mac if n not in phone]
        extra = [n for n in phone if n not in mac]
        check(self.ws_name in phone, f"seeded workspace {self.ws_name} missing on the phone; phone shows {phone}")
        check(not missing and not extra, f"list mismatch: missing {missing}, extra {extra}"
                                          + ("" if has_kind else " (the Mac's workspace list has no `kind`, so its home "
                                                                 "workspace could not be left out)"))
        return f"{len(phone)} rows match the Mac ({', '.join(phone[:6])})"

    def s_create_workspace(self):
        self.back_to_list()
        before = {w["id"] for w in self.mac.cmux("workspace", "list", json_out=True)}
        t = self.sim.tap_q(ident="workspaces.new")
        new, kind, t_open = None, None, None
        while time.time() - t < 20:
            els = self.sim.tree()
            if kind is None:
                if self.sim.find(ident="terminal.composer.field", elements=els):
                    kind, t_open = "terminal", time.time() - t
                elif self.sim.find(contains="Search or enter website", elements=els):
                    kind, t_open = "browser address bar", time.time() - t
                    self.sim.shot(f"create-page-{self.run_id}")
            now = self.mac.cmux("workspace", "list", json_out=True)
            new = [w for w in now if w["id"] not in before]
            if new and kind:
                break
            time.sleep(0.3)
        t_mac = time.time() - t
        self.back_to_list()
        if new:
            self.mac.cmux("workspace", new[0]["id"], "close", check=False)
        check(new, f"tap New Workspace: no workspace reached the Mac in 20 s; the phone showed {kind or 'nothing'} "
                   f"(optimistic page {'never confirmed' if kind else 'missing'})")
        check(kind == "terminal", f"the new workspace opened on {kind}, expected the Mac's default terminal")
        return {"notes": f"'{new[0]['name']}' on the Mac in {t_mac:.2f} s; phone showed its terminal in {t_open:.2f} s (closed afterwards)",
                "metric_create_mac_s": round(t_mac, 2)}

    def s_open_workspace(self):
        dt = self.open_seed_workspace()
        title = [e.label for e in self.sim.find(kind="Button") if (e.label or "").startswith(("e2e-t", "azizalbahar", "~"))]
        return {"notes": f"opened {self.ws_name} on a terminal in {dt:.2f} s; toolbar {title[:2]}"}

    def tab_grid_pick(self, name):
        self.dismiss_system()
        self.hide_keyboard()
        self.sim.tap_q(label="Tabs", kind="Button")
        time.sleep(1.2)
        # Cards are labelled "<title>, <kind>" (e.g. "e2e-t2, tab"): match the start.
        cand = self.sim.wait(prefix=name, kind="Button", timeout=8)
        if cand and cand.label != name:
            self.grid_notes.append(f"grid card '{cand.label}'")
        check(cand, f"tab grid has no {name}")
        self.sim.tap_el(cand)
        time.sleep(1.5)

    def current_tab_marker(self):
        """Writes a marker through the phone's terminal and returns which Mac terminal got it."""
        marker = f"m{random.randint(10000, 99999)}"
        self.sim.tap_q(ident="terminal.composer.field")
        time.sleep(0.6)
        self.sim.dismiss_keyboard_intro()
        self.sim.softtype(f"echo {marker}")
        self.sim.tap_q(ident="terminal.composer.send")
        time.sleep(2.0)
        self.hide_keyboard()
        return self.which_term(marker)

    def s_last_tab_restore(self):
        self.open_seed_workspace()
        self.tab_grid_pick("e2e-t2")
        term = self.current_tab_marker()
        check(term == self.seed["term2"], f"after picking e2e-t2 input reached {term}, expected {self.seed['term2']}")
        self.back_to_list()
        self.open_seed_workspace()
        term = self.current_tab_marker()
        check(term == self.seed["term2"], f"reopened workspace did not restore e2e-t2 (input went to {term})")
        self.tab_grid_pick("e2e-t1")
        term = self.current_tab_marker()
        check(term == self.seed["term1"], "switching back to e2e-t1 failed")
        return "reopened on the last tab (e2e-t2); grid switch back to e2e-t1"

    def s_term_direct(self):
        self.open_seed_workspace()
        self.focus_terminal()
        marker = f"d{random.randint(10000, 99999)}"
        self.sim.softtype(f"echo {marker}\n")
        self.mac_wait_text(self.seed["term1"], marker, count=2)
        return f"typed 'echo {marker}' + return on the software keyboard; the Mac ran it"

    def s_term_composer(self):
        self.open_seed_workspace()
        self.hide_keyboard()
        self.sim.tap_q(ident="terminal.composer.field")
        time.sleep(0.6)
        marker = f"c{random.randint(10000, 99999)}"
        self.sim.softtype(f"echo {marker}")
        self.sim.tap_q(ident="terminal.composer.send")
        self.mac_wait_text(self.seed["term1"], marker, count=2)
        self.hide_keyboard()
        return f"composer sent 'echo {marker}'"

    def s_relaunch_restore(self):
        """design/terminal R1-0: a cold launch restores the open terminal tab and it
        attaches (accepts input) within 10 s, showing its last frame meanwhile."""
        self.open_seed_workspace()
        self.hide_keyboard()
        time.sleep(1)
        self.sim.terminate(BUNDLE)
        time.sleep(1)
        t = self.sim.launch(BUNDLE)
        field = self.sim.wait(ident="terminal.composer.field", timeout=15)
        check(field, "the relaunch did not restore the terminal tab")
        restored = time.time() - t
        connecting = bool(self.sim.find(ident="terminal.connecting"))
        self.sim.shot(f"relaunch-restore-{self.run_id}")
        # Attached: the connecting placeholder goes away within 10 s of launch.
        while self.sim.find(ident="terminal.connecting") and time.time() - t < 10:
            time.sleep(0.3)
        check(not self.sim.find(ident="terminal.connecting"),
              f"still connecting {time.time() - t:.0f} s after the relaunch (R1-0)")
        attached = time.time() - t
        marker = f"r{random.randint(10000, 99999)}"
        self.sim.tap_el(field)
        time.sleep(0.6)
        self.sim.softtype(f"echo {marker}")
        self.sim.tap_q(ident="terminal.composer.send")
        deadline = time.time() + 8
        while time.time() < deadline and not self.which_term(marker):
            time.sleep(0.4)
        check(self.which_term(marker), f"input after the relaunch never reached the Mac ({marker})")
        ran = time.time() - t
        self.hide_keyboard()
        return {"notes": f"restored the tab in {restored:.1f} s ({'connecting label shown' if connecting else 'no connecting label'}); "
                         f"attached {attached:.1f} s and the Mac ran input {ran:.1f} s after launch",
                "metric_relaunch_attach_s": round(attached, 2)}

    def pull_until(self, needle, tries=8):
        """Pull-downs above the keyboard (y 150 -> 400) until `needle` is on screen.
        Returns (pulls, ocr hits)."""
        for pulls in range(tries + 1):
            hits = self.sim.ocr_find(needle, timeout=1.5)
            if hits:
                return pulls, hits
            self.sim.drag(201, 150, 201, 400, duration=0.5, hold=0.3)
            time.sleep(0.8)
        return tries, []

    def s_tui_quit_keyboard_up(self):
        """design/terminal R2-1, R3-1: `top` with the keyboard up, then `q`: the
        prompt is above the composer, and pull-downs above the keyboard scroll
        back to the output from before `top` (the content moves)."""
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        marker = f"H{random.randint(10000, 99999)}"
        self.mac_write(term, f"clear; echo {marker}; seq 1 40\n")
        self.mac_wait_text(term, marker, timeout=8, count=1)
        self.sim.tap_q(ident="terminal.composer.field")
        time.sleep(0.8)
        self.sim.softtype("top")
        self.sim.tap_q(ident="terminal.composer.send")
        time.sleep(4)
        check(self.sim.keyboard(), "the keyboard went down while top ran")
        self.sim.softtype("q")
        self.sim.tap_q(ident="terminal.composer.send")
        time.sleep(3)
        self.sim.shot(f"tui-quit-kbup-{self.run_id}")
        check(self.sim.keyboard(), "the keyboard went down after q")
        top_line = [o for o in self.sim.ocr() if o[4].strip().endswith("top")]
        check(top_line, "the `top` command line is not on screen after q (R2-1)")
        before = min(o[1] for o in top_line)
        pulls, seen = self.pull_until(marker)
        self.sim.shot(f"tui-quit-kbup-pulled-{self.run_id}")
        check(seen, f"pull-downs above the keyboard never reached the output before top ({marker}) (R3-1)")
        after = [o for o in self.sim.ocr() if o[4].strip().endswith("top")]
        moved = pulls > 0 and (not after or min(o[1] for o in after) > before + 10)
        check(pulls == 0 or moved, "the pull-down did not move the content (R3-1)")
        self.hide_keyboard()
        return f"after q with the keyboard up: `top` line at y {before:.0f} pt; {marker} reached after {pulls} pull-down(s)" + \
               (", the content moved" if pulls else " (already on screen)")

    def scroll_to_find(self, needle, tries=24):
        """Fast pull-downs (keyboard down) until `needle` is on screen."""
        for flicks in range(tries + 1):
            hits = self.sim.ocr_find(needle, timeout=1.0)
            if hits:
                return flicks, hits
            self.sim.swipe(201, 200, 201, 760, duration=0.12)
            time.sleep(0.9)
        return tries, []

    def s_scrollback_history(self):
        """User report 2026-10-14: the phone must reach the same first line of
        history as the Mac. (a) 300 lines written on the Mac before the phone
        attaches (the attach replay carries the history); (b) an inline TUI's
        history (Codex CLI style: a scroll region from the top, then a line feed
        per line) printed while the phone is attached."""
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        first = f"FIRST{random.randint(10000, 99999)}"
        self.mac_write(term, f"clear; echo {first}; seq 2 300\n")
        self.mac_wait_text(term, "\n300", timeout=10)
        # A fresh attach: relaunch (restores this tab), so the history comes in the replay.
        self.sim.terminate(BUNDLE); time.sleep(1); self.sim.launch(BUNDLE)
        check(self.sim.wait(ident="terminal.composer.field", timeout=15), "the relaunch did not restore the terminal")
        while self.sim.find(ident="terminal.connecting"):
            time.sleep(0.3)
        time.sleep(1.5)
        flicks_a, seen_a = self.scroll_to_find(first)
        self.sim.shot(f"history-replay-top-{self.run_id}")
        check(seen_a, f"after a fresh attach, scrolling up never reached the first line ({first}) of 300 written on the Mac")
        # (b) Codex CLI style history, live.
        jump = self.sim.find(label="Scroll to bottom")
        if jump:
            self.sim.tap_el(jump[0]); time.sleep(1)
        cx = f"CXTOP{random.randint(10000, 99999)}"
        script = ("clear; printf '\\033[1;12r\\033[12;1H'; printf '\\r\\n%s' " + cx +
                  "; for i in $(seq 1 150); do printf '\\r\\nCX%03d' $i; done; printf '\\033[r\\033[999;1H\\nCXDONE\\n'\n")
        self.mac_write(term, script)
        self.mac_wait_text(term, "\nCXDONE", timeout=10)
        time.sleep(1.5)
        flicks_b, seen_b = self.scroll_to_find(cx)
        self.sim.shot(f"history-inline-top-{self.run_id}")
        check(seen_b, f"lines an inline TUI printed with a scroll region from the top are not in the phone's history ({cx})")
        jump = self.sim.find(label="Scroll to bottom")
        if jump:
            self.sim.tap_el(jump[0]); time.sleep(1)
        return (f"first of 300 lines ({first}) reached after a fresh attach in {flicks_a} flick(s); "
                f"Codex-style region history ({cx} + 150 lines) reached in {flicks_b} flick(s)")

    def composer_card_top(self):
        """Top of the composer card: the highest of its field, its + button and
        its attachment chips, less the card's 6 pt padding."""
        els = self.sim.tree()
        tops = [e.frame[1] for e in els if e.ident == "terminal.composer.field" or e.label == "Add attachment"
                or (e.kind == "Image" and re.search(r"\.(jpe?g|png|heic|mov)$", e.label or "", re.I))]
        return (min(tops) - 6) if tops else None

    def check_last_row(self, marker, state):
        hits = self.sim.ocr_find(marker, timeout=4)
        top = self.composer_card_top()
        self.sim.shot(f"composer-pin-{state.replace(' ', '-')}-{self.run_id}")
        check(hits, f"{state}: the last row ({marker}) is not visible (under the composer?)")
        check(top is not None, f"{state}: no composer")
        bottom = max(h[1] + h[3] for h in hits)
        check(bottom <= top - 4, f"{state}: the last row ends at y {bottom:.0f} pt, the composer starts at {top:.0f} pt (user report)")
        return f"{state}: row ends {bottom:.0f}, composer {top:.0f}"

    def s_composer_bottom_pin(self):
        """User report 2026-10-14: the last terminal row rests above the composer
        (8 pt), never under it: keyboard down, keyboard up, a 3-line draft, an
        attachment strip; also with rows an inline TUI draws below the cursor."""
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        marker = f"LAST{random.randint(10000, 99999)}"
        # The cursor stays on the prompt row with a hint row drawn below it (Codex CLI-like).
        self.mac_write(term, f"clear; seq 1 60; printf '> \\n{marker}\\033[1A\\r> '; sleep 300\n")
        self.mac_wait_text(term, marker, timeout=10)
        time.sleep(1.5)
        notes = [self.check_last_row(marker, "keyboard down")]
        self.sim.tap_q(ident="terminal.composer.field"); time.sleep(1.2)
        notes.append(self.check_last_row(marker, "keyboard up"))
        self.sim.softtype("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen")
        time.sleep(1.2)
        notes.append(self.check_last_row(marker, "3-line draft"))
        # Attachment strip (the photo picker, as in image_upload).
        try:
            add = self.sim.find(label="Add attachment")
            if add:
                self.hide_keyboard()
                self.sim.press(*add[0].center, hold=0.1); time.sleep(1.2)
                photos = self.sim.find(label="Photos", kind="Button")
                files = self.sim.find(label="Files", kind="Button")
                if photos or files:
                    x, y = photos[0].center if photos else (files[0].center[0], files[0].center[1] + 63)
                    self.sim.press(x, y, hold=0.1); time.sleep(3)
                    self.sim.tap(200, 412); time.sleep(1)
                    self.sim.tap(363, 144); time.sleep(2.5)
                chip = [e for e in self.sim.find(kind="Image") if re.search(r"\.(jpe?g|png|heic)$", e.label or "", re.I)]
                if chip:
                    notes.append(self.check_last_row(marker, "attachment strip"))
                else:
                    notes.append("attachment strip: not reached (picker)")
        finally:
            for e in self.sim.find(kind="Button"):
                if (e.label or "").startswith("Remove "):
                    self.sim.tap_el(e); time.sleep(0.5)
            self.sim.tap_q(ident="terminal.composer.field"); time.sleep(0.8)
            self.keybar("Control C"); time.sleep(0.5)
            self.sim.tap_q(ident="terminal.composer.send"); time.sleep(1)
            self.hide_keyboard()
        return "; ".join(notes)

    BRACKETED_FAKE = r"""
import os, sys, tty, termios
log = open(sys.argv[1], "w")
fd = 0
old = termios.tcgetattr(fd)
tty.setraw(fd)
os.write(1, b"\x1b[?2004hREADY\r\n")
seen = []
try:
    while True:
        chunk = os.read(fd, 4096)
        seen.append(chunk)
        log.write(repr(chunk) + "\n"); log.flush()
        if b"\r" in chunk:
            break
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    os.write(1, b"\x1b[?2004l")
data = b"".join(seen)
pasted = data.startswith(b"\x1b[200~") and b"\x1b[201~" in data
alone = seen[-1] == b"\r"
print("SUBMIT-" + ("OK" if pasted and alone else "MERGED" if pasted else "UNBRACKETED"), len(seen), "reads")
"""

    def s_composer_submit(self):
        """Codex QA F1: the composer's Send reaches a program that reads in bursts
        (Codex) as one bracketed paste, then Return in a read of its own, so it
        submits instead of staying a draft. A fake program logs each read."""
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        script = f"/tmp/cmux-mobile-e2e-{self.run_id}-bp.py"
        log = f"/tmp/cmux-mobile-e2e-{self.run_id}-bp.log"
        open(script, "w").write(self.BRACKETED_FAKE)
        self.mac_write(term, f"clear; python3 {script} {log}\n")
        self.mac_wait_text(term, "READY", timeout=10)
        self.sim.tap_q(ident="terminal.composer.field"); time.sleep(0.8)
        self.sim.softtype("say hi in two words")
        self.sim.tap_q(ident="terminal.composer.send")
        text = self.mac_wait_text(term, "SUBMIT-", timeout=10)
        reads = open(log).read().strip().splitlines()
        self.hide_keyboard()
        check("SUBMIT-OK" in text, f"Send did not arrive as a paste followed by a separate Return: {text[-80:]!r}; reads {reads}")
        return f"one bracketed paste, then Return in its own read ({len(reads)} reads: {reads[-1]})"

    def s_tab_switch_last_row(self):
        """Codex QA F8: after switching to another tab and back, the row an inline
        TUI keeps below its cursor (Codex's status row, updated every second)
        rests above the composer on the first frames, not half under it."""
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        tag = f"ST{random.randint(100, 999)}"
        self.mac_write(term, "clear; seq 1 50; printf '> '; i=0; while true; do printf '\\0337\\n\\033[2K" + tag +
                       "-%04d\\0338' $i; i=$((i+1)); sleep 1; done\n")
        self.mac_wait_text(term, f"{tag}-0002", timeout=12)
        notes = [self.check_last_row(tag, "before the switch")]
        try:
            # To a new tab (the QA pass used a browser tab; this Mac build offers
            # a terminal), then back.
            self.dismiss_system(); self.hide_keyboard()
            self.sim.tap_q(label="Tabs", kind="Button"); time.sleep(1.2)
            plus = [e for e in self.sim.find(kind="Button") if not e.label and e.frame[1] > 700 and e.frame[0] < 120]
            check(plus, "no + in the tab grid")
            self.sim.tap_el(plus[0]); time.sleep(1.0)
            new = self.sim.find(contains="Browser") or self.sim.find(label="New Terminal", kind="Button")
            check(new, "no New Browser Tab / New Terminal in the + menu")
            self.sim.tap_el(new[0]); time.sleep(2.5)
            self.tab_grid_pick("e2e-t1"); time.sleep(0.8)
            notes.append(self.check_last_row(tag, "0.8 s after switching back"))
        finally:
            try:
                self.sim.tap_q(ident="terminal.composer.field"); time.sleep(0.8)
                self.keybar("Control C"); time.sleep(0.5)
                self.hide_keyboard()
            except Exception:
                pass
        return "; ".join(notes)

    def top_number(self):
        """The smallest y (and its number) of a bare number row on screen (Codex's reply)."""
        best = None
        for o in self.sim.ocr():
            t = o[4].strip().lstrip("•").strip()
            if t.isdigit() and 60 < o[1] < 700 and (best is None or o[1] < best[0]):
                best = (round(o[1]), int(t))
        return best

    def s_codex_scroll_hold(self):
        """Codex QA F2 with the real Codex CLI (model calls: only with
        CMUX_MOBILE_E2E_REAL_CODEX=1): scrolled up while a long reply streams, the rows
        under the finger stay put until the person scrolls back or types."""
        if os.environ.get("CMUX_MOBILE_E2E_REAL_CODEX") != "1":
            raise Blocked("needs CMUX_MOBILE_E2E_REAL_CODEX=1 (the real Codex CLI makes model calls)")
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        proj = os.path.expanduser("~/cmux-next-ios-e2e/codexqa-proj")
        os.makedirs(proj, exist_ok=True)
        self.mac_write(term, f"clear; cd {proj} && codex\n")
        deadline = time.time() + 40
        while time.time() < deadline:
            text = self.mac_screen(term).get("text", "")
            if "trust" in text.lower() and "1." in text:
                self.mac_write(term, "\r"); time.sleep(2)
            if "›" in text and "trust" not in text.lower():
                break
            time.sleep(1)
        self.sim.tap_q(ident="terminal.composer.field"); time.sleep(0.8)
        self.sim.softtype("write a 150 line story about a terminal, each line numbered like 1. text")
        self.sim.tap_q(ident="terminal.composer.send")
        self.hide_keyboard()
        # Wait for the numbers to stream.
        deadline = time.time() + 60
        while time.time() < deadline and "10. " not in self.mac_screen(term).get("text", ""):
            time.sleep(0.5)
        self.sim.drag(201, 250, 201, 550, duration=0.5, hold=0.3)
        time.sleep(1.0)
        # The terminal band must not change while the reply streams below it.
        shots = []
        for i in range(12):
            shots.append(self.sim.shot(f"codex-scroll-hold-{self.run_id}-{i:02d}"))
            time.sleep(0.6)
        live = self.mac_screen(term).get("text", "")
        from PIL import Image, ImageChops
        def band(path):
            # The terminal band, without the scroll indicator at the right edge.
            return Image.open(path).convert("L").crop((0, 200, 1140, 1900))
        first = band(shots[0])
        moved = [i for i, path in enumerate(shots[1:], 1) if ImageChops.difference(first, band(path)).getbbox()]
        self.mac_write(term, "\x03"); time.sleep(0.5); self.mac_write(term, "\x03")
        check(not moved, f"the view moved by itself while scrolled up (F2): frames {moved} of 12 differ from the first")
        return "held for 7 s while Codex streamed (12 frames, identical terminal band)"

    def s_joystick_paste_close(self):
        """Codex QA F5: a joystick flick sends exactly one arrow and a 1.2 s hold
        about ten; F14: the key bar's Paste is the system paste control; F9:
        closing a tab that runs a program asks first, and Cancel keeps it."""
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        self.sim.tap_q(ident="terminal.composer.field"); time.sleep(0.8)
        self.focus_terminal()
        self.sim.softtype("echo abcdefghijklmnopqrstuvwxyz0123456789")
        time.sleep(1)
        js = self.sim.find(label="Cursor joystick")
        check(js, "no joystick")
        cx, cy = js[0].center
        before = self.mac_screen(term).get("cursor_col")
        self.sim.drag(cx, cy, cx - 22, cy, duration=0.12, hold=0.0)
        time.sleep(0.8)
        flick = self.mac_screen(term).get("cursor_col")
        self.sim.drag(cx, cy, cx - 30, cy, duration=0.2, hold=1.0)
        time.sleep(0.8)
        held = self.mac_screen(term).get("cursor_col")
        self.keybar("Control C"); time.sleep(0.5)
        check(None not in (before, flick, held), f"no cursor column from the Mac ({before}, {flick}, {held})")
        check(before - flick == 1, f"a flick moved the cursor {before - flick} columns, not 1 (F5)")
        moved = flick - held
        check(3 <= moved <= 14, f"a ~1.2 s hold moved the cursor {moved} columns (F5: about 10 expected)")
        notes = [f"flick: 1 column; 1.2 s hold: {moved} columns"]
        paste = self.sim.find(ident="terminal.key.paste")
        if not paste:
            self.keybar_reveal("Paste")
            paste = self.sim.find(ident="terminal.key.paste")
        notes.append("key bar Paste is the system paste control" if paste else "key bar Paste control not found in the tree")
        self.hide_keyboard()
        # F9: a program running in the tab: close asks first.
        self.mac_write(term, "clear; vim /tmp/cmux-mobile-e2e-close-check.txt\n")
        time.sleep(2.5)
        self.sim.tap_q(label="Tabs", kind="Button"); time.sleep(1.2)
        close = [e for e in self.sim.find(kind="Button") if (e.label or "").startswith("Close ") and "e2e-t1" in (e.label or "")]
        alert = None
        if close:
            self.sim.tap_el(close[0]); time.sleep(1.2)
            alert = self.sim.find(label="Close Tab", kind="Button")
            cancel = self.sim.find(label="Cancel", kind="Button")
            if cancel:
                self.sim.tap_el(cancel[0]); time.sleep(1)
        kept = self.sim.find(prefix="e2e-t1", kind="Button")
        self.tab_grid_pick("e2e-t1")
        self.mac_write(term, "\x1b:q!\r")
        time.sleep(1)
        notes.append("close of a tab running vim: " + ("asked, Cancel kept it" if alert and kept else
                     "no confirmation (the tab title may not name the program on this Mac build)"))
        return "; ".join(notes)

    def band_changes(self, video, top=0.08, bottom=0.45, threshold=2.0):
        """Real changes of the terminal's upper band between consecutive 30 fps
        frames of `video`, and frames where that band is black."""
        import shutil, subprocess, glob
        from PIL import Image, ImageChops, ImageStat
        d = video + ".frames"
        shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-i", video, "-vf", "fps=30,scale=402:-1", f"{d}/%04d.png"], check=True)
        prev, changes, black = None, [], []
        for i, f in enumerate(sorted(glob.glob(f"{d}/*.png"))):
            im = Image.open(f).convert("L"); w, h = im.size
            band = im.crop((0, int(h * top), w - 12, int(h * bottom)))
            if max(band.getdata()) < 60:
                black.append(i)
            if prev is not None and ImageStat.Stat(ImageChops.difference(prev, band)).mean[0] > threshold:
                changes.append(i)
            prev = band
        shutil.rmtree(d, ignore_errors=True)
        return changes, black

    def s_reattach_no_jumps(self):
        """User report 2026-10-14 ("blinking and oscillating"): after a reattach
        with a long history (the Mac replays it after a reset), the page shows
        its last frame, then the live bottom once: no passes through old
        history, no black frames."""
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        # About 2 MB of styled history, like a long Codex transcript: the Mac's
        # replay is fed over many display frames.
        self.mac_write(term, "clear; python3 -c \"[print(f'\\x1b[3{i%7}mline {i} '+'x'*60+'\\x1b[0m') for i in range(1,24001)]\"; echo ENDMARK\n")
        self.mac_wait_text(term, "ENDMARK", timeout=60)
        time.sleep(2)
        self.sim.home()
        time.sleep(45)  # long enough for the link to drop: the tab reattaches and the Mac replays
        video = os.path.join(self.out, f"reattach-{self.run_id}.mp4")
        self.sim.record_start(video)
        time.sleep(0.5)
        self.sim.launch(BUNDLE, terminate=False)
        time.sleep(7)
        self.sim.record_stop()
        changes, black = self.band_changes(video)
        self.sim.shot(f"reattach-after-{self.run_id}")
        # From 1.5 s after the launch (the app's opening animation is over):
        # at most one swap (held frame -> live bottom), no black frames.
        settled = int(2.0 * 30)
        late_changes = [i for i in changes if i >= settled]
        late_black = [i for i in black if i >= settled]
        check(not late_black, f"black terminal frames after the reattach: {late_black}")
        check(len(late_changes) <= 2, f"the page passed through {len(late_changes)} positions after the reattach: frames {late_changes}")
        return f"reattach with 24000 styled rows of history: {len(late_changes)} band change(s) after the opening, no black frames"

    def s_no_resize_on_scroll(self):
        """User report 2026-10-14 (resize loop): scrolling up shows Jump to bottom
        in the composer card; that must not resize the PTY (an inline TUI such as
        Codex redraws its whole transcript on every resize). A shell counts
        SIGWINCH while the reader scrolls up and back."""
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        self.mac_write(term, "clear; trap 'echo WINCH' WINCH; seq 1 200; echo READY; while :; do sleep 1; done\n")
        self.mac_wait_text(term, "READY", timeout=10)
        time.sleep(1.5)
        for _ in range(2):
            self.sim.drag(201, 300, 201, 520, duration=0.5, hold=0.3); time.sleep(2.5)
            jump = self.sim.find(label="Scroll to bottom")
            if jump:
                self.sim.tap_el(jump[0]); time.sleep(2.5)
        text = self.mac_screen(term).get("text", "")
        self.mac_write(term, "\x03"); time.sleep(0.5)
        winches = text.count("WINCH")
        check(winches == 0, f"scrolling up and back resized the PTY {winches} time(s) (Jump to bottom in the composer resized it)")
        return "scrolling up and back (Jump to bottom shown and tapped twice): no resize"

    def s_codex_reset_watch(self):
        """User report 2026-10-14 diagnosis (real Codex, CMUX_MOBILE_E2E_REAL_CODEX=1):
        Codex working with a long transcript, keyboard down, nobody touching:
        logs every PTY resize and mirror reset with its cause and records the
        page; no resets or resizes may happen and the view must not move."""
        if os.environ.get("CMUX_MOBILE_E2E_REAL_CODEX") != "1":
            raise Blocked("needs CMUX_MOBILE_E2E_REAL_CODEX=1 (the real Codex CLI makes model calls)")
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        proj = os.path.expanduser("~/cmux-next-ios-e2e/codexqa-proj")
        os.makedirs(proj, exist_ok=True)
        self.mac_write(term, f"clear; cd {proj} && codex\n")
        deadline = time.time() + 40
        while time.time() < deadline:
            text = self.mac_screen(term).get("text", "")
            if "trust" in text.lower() and "1." in text:
                self.mac_write(term, "\r"); time.sleep(2)
            if "›" in text and "trust" not in text.lower():
                break
            time.sleep(1)
        self.sim.tap_q(ident="terminal.composer.field"); time.sleep(0.8)
        self.sim.softtype("write a 120 line numbered story, then run ls and sleep 20 in the shell and summarize")
        self.sim.tap_q(ident="terminal.composer.send")
        self.hide_keyboard()
        time.sleep(12)
        video = os.path.join(self.out, f"codex-watch-{self.run_id}.mp4")
        start = time.time()
        self.sim.record_start(video)
        time.sleep(20)
        self.sim.record_stop()
        logs = subprocess.run(["xcrun", "simctl", "spawn", self.sim.udid, "log", "show", "--last", f"{int(time.time() - start) + 5}s",
                               "--style", "compact", "--predicate",
                               'subsystem == "dev.cmux.mobile" AND (category == "terminal-sizing" OR category == "terminal")', "--debug"],
                              capture_output=True, text=True).stdout
        events = [l for l in logs.splitlines() if "resize" in l or "mirror reset" in l]
        open(os.path.join(self.out, f"codex-watch-{self.run_id}.log"), "w").write("\n".join(events))
        changes, black = self.band_changes(video, top=0.08, bottom=0.40)
        self.mac_write(term, "\x03"); time.sleep(0.5); self.mac_write(term, "\x03")
        check(not events, f"{len(events)} resize/reset events while nobody touched the page: {events[:6]}")
        check(not black, f"black frames: {black[:10]}")
        return f"20 s of Codex working, keyboard down: no resize or reset; {len(changes)} upper-band changes (Codex output)"

    def s_scroll_to_bottom_stable(self):
        """User report 2026-10-14 ("weird frame oscillation when I scroll to the
        bottom"): scrolling down into the bottom of a long transcript, the page
        never shows another region for a frame, and once released it settles."""
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        self.mac_write(term, "clear; python3 -c \"[print(f'\\x1b[4{i%7}m row {i:04d} \\x1b[0m' + ' text'*8) for i in range(1,601)]\"; echo BOTTOMMARK\n")
        self.mac_wait_text(term, "BOTTOMMARK", timeout=20)
        time.sleep(1.5)
        for _ in range(3):
            self.sim.swipe(201, 250, 201, 750, duration=0.15); time.sleep(0.8)
        time.sleep(1.5)
        video = os.path.join(self.out, f"to-bottom-{self.run_id}.mp4")
        self.sim.record_start(video)
        time.sleep(0.3)
        for _ in range(4):
            self.sim.swipe(201, 600, 201, 120, duration=0.15); time.sleep(0.7)
        for _ in range(3):
            self.sim.drag(201, 600, 201, 150, duration=0.35, hold=0.0); time.sleep(0.6)
        time.sleep(3)
        self.sim.record_stop()
        import shutil, subprocess as sp, glob
        from PIL import Image, ImageChops, ImageStat
        d = video + ".frames"
        shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
        sp.run(["ffmpeg", "-loglevel", "error", "-i", video, "-vf", "fps=60,scale=402:-1", f"{d}/%04d.png"], check=True)
        bands = []
        for f in sorted(glob.glob(f"{d}/*.png")):
            im = Image.open(f).convert("L"); w, h = im.size
            bands.append(im.crop((0, int(h * 0.08), w - 12, int(h * 0.72))))
        shutil.rmtree(d, ignore_errors=True)
        def diff(a, b): return ImageStat.Stat(ImageChops.difference(a, b)).mean[0]
        # A frame of another region: far from both neighbors while they match each other.
        flips = [i for i in range(1, len(bands) - 1)
                 if diff(bands[i - 1], bands[i + 1]) < 4 and diff(bands[i], bands[i - 1]) > 15]
        black = [i for i, b in enumerate(bands) if max(b.getdata()) < 60]
        settled = bands[-60:]
        moving = [i for i in range(1, len(settled)) if diff(settled[i], settled[i - 1]) > 2]
        check(not flips, f"frames showing another region on the way to the bottom: {flips}")
        check(not black, f"black frames: {black[:10]}")
        check(not moving, "the page still moved after it settled at the bottom")
        jump = self.sim.find(label="Scroll to bottom")
        check(not jump, "not at the bottom after scrolling down (Jump to bottom still shown)")
        return f"scrolled into the bottom: {len(bands)} frames at 60 fps, no frame of another region, settled"

    STREAMER = r"""
import sys, time
w = sys.stdout.write
for i in range(1, 801):
    w("\r\x1b[2K" + ("\x1b[4%dm" % (i % 7)) + " out %04d \x1b[0m" % i + " text" * 8 + "\n")
    w("\x1b[2K\x1b[2mWorking (%ds) - esc to interrupt\x1b[0m" % (i // 20))
    sys.stdout.flush()
    time.sleep(0.05)
w("\r\x1b[2KSTREAMDONE\n")
"""

    def s_scroll_while_streaming(self):
        """User reports 2026-10-14 (oscillation near the bottom; "super buggy
        and unsmooth" while the agent works): with ~20 lines/s streaming and a
        status line redrawn below, drag up, fling, drag down and fling to the
        bottom; at 60 fps no frame shows another region, no black frame, and
        the page ends following the bottom."""
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        script = f"/tmp/cmux-mobile-e2e-{self.run_id}-stream.py"
        open(script, "w").write(self.STREAMER)
        self.mac_write(term, f"clear; seq 1 300; python3 {script}\n")
        self.mac_wait_text(term, " out 0060 ", timeout=15)
        video = os.path.join(self.out, f"stream-scroll-{self.run_id}.mp4")
        self.sim.record_start(video)
        time.sleep(0.3)
        self.sim.drag(201, 250, 201, 600, duration=0.6, hold=0.2); time.sleep(0.8)   # drag up (reading)
        self.sim.swipe(201, 250, 201, 700, duration=0.12); time.sleep(1.5)           # fling up
        self.sim.drag(201, 600, 201, 250, duration=0.6, hold=0.2); time.sleep(0.8)   # drag down
        for _ in range(4):
            self.sim.swipe(201, 600, 201, 120, duration=0.12); time.sleep(0.9)       # fling to the bottom
        time.sleep(2)
        self.sim.record_stop()
        import shutil, subprocess as sp, glob
        from PIL import Image, ImageChops, ImageStat
        d = video + ".frames"
        shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
        sp.run(["ffmpeg", "-loglevel", "error", "-i", video, "-vf", "fps=60,scale=402:-1", f"{d}/%04d.png"], check=True)
        bands = []
        for f in sorted(glob.glob(f"{d}/*.png")):
            im = Image.open(f).convert("L"); w, h = im.size
            bands.append(im.crop((0, int(h * 0.08), w - 12, int(h * 0.72))))
        shutil.rmtree(d, ignore_errors=True)
        def diff(a, b): return ImageStat.Stat(ImageChops.difference(a, b)).mean[0]
        flips = [i for i in range(1, len(bands) - 1)
                 if diff(bands[i - 1], bands[i + 1]) < 4 and diff(bands[i], bands[i - 1]) > 15 and diff(bands[i], bands[i + 1]) > 15]
        black = [i for i, b in enumerate(bands) if max(b.getdata()) < 60]
        self.sim.shot(f"stream-scroll-end-{self.run_id}")
        following = not self.sim.find(label="Scroll to bottom")
        self.mac_write(term, "\x03")
        check(not flips, f"frames showing another region: {flips}")
        check(not black, f"black frames: {black[:10]}")
        check(following, "not following the bottom after flinging to it (Jump to bottom shown)")
        return f"{len(bands)} frames at 60 fps while streaming: no frame of another region, no black frame, following at the end"

    def s_keybar_swipe_no_back(self):
        """design/terminal R4-1: with the keyboard up, a rightward swipe that starts
        on the key bar (pinned ^C, the scroller, the joystick) stays on the
        terminal; it never swipes back to the workspaces."""
        self.open_seed_workspace()
        self.hide_keyboard()
        self.sim.tap_q(ident="terminal.composer.field")
        time.sleep(1.2)
        starts = []
        for label in ("Control C", "More keys", "Cursor joystick"):
            found = [e for e in self.sim.find(label=label) if e.frame[2] > 20]
            check(found, f"key bar has no {label!r}")
            x, y = found[0].center
            self.sim.drag(x, y, min(395, x + 220), y, duration=0.35, hold=0.05)
            time.sleep(1.5)
            still = self.sim.find(ident="terminal.composer.field")
            self.sim.shot(f"keybar-swipe-{label.replace(' ', '-').lower()}-{self.run_id}")
            check(still, f"a rightward swipe from {label!r} left the terminal (swiped back) (R4-1)")
            starts.append(f"{label} at x {x:.0f}")
        self.hide_keyboard()
        return "rightward swipes from " + ", ".join(starts) + " stayed on the terminal"

    def s_shell_pull_keyboard_up(self):
        """design/terminal R3-1: a plain shell with the keyboard up: `seq 1 80`, a
        pull-down above the keyboard scrolls the history back to its start; a drag
        into the keyboard still dismisses it with the prompt on the composer."""
        self.open_seed_workspace()
        self.hide_keyboard()
        marker = f"S{random.randint(10000, 99999)}"
        self.sim.tap_q(ident="terminal.composer.field")
        time.sleep(0.8)
        self.sim.softtype(f"clear; echo {marker}; seq 1 80")
        self.sim.tap_q(ident="terminal.composer.send")
        self.mac_wait_text(self.seed["term1"], "\n80", timeout=8, count=1)
        time.sleep(1.5)
        check(self.sim.keyboard(), "the keyboard went down after sending")
        pulls, seen = self.pull_until(marker, tries=10)
        self.sim.shot(f"shell-pull-kbup-{self.run_id}")
        check(pulls > 0, "the marker was on screen before any pull (the step needs history above the screen)")
        check(seen, f"pull-downs above the keyboard never reached row 1 of `seq 1 80` ({marker}) (R3-1)")
        # Back to the prompt, then a drag into the keyboard dismisses it (M6).
        jump = self.sim.find(label="Scroll to bottom")
        if jump:
            self.sim.tap_el(jump[0]); time.sleep(1)
        self.sim.drag(201, 300, 201, 860, duration=1.2, hold=0.3)
        time.sleep(1.5)
        self.sim.shot(f"shell-pull-dismiss-{self.run_id}")
        check(not self.sim.keyboard(), "a drag into the keyboard did not dismiss it")
        check(not self.sim.find(label="Scroll to bottom"), "the dismissal left the prompt (jump-to-bottom shown) (M6)")
        return f"row 1 ({marker}) reached after {pulls} pull-down(s) with the keyboard up; a drag into the keyboard dismissed it on the prompt"

    def s_term_keys(self):
        try:
            return self._term_keys()
        finally:
            # Leave a clean line for the next step whatever happened (R1-6):
            # ^C drops a half-typed command, then the keyboard goes.
            try:
                pinned = self.sim.find(ident="terminal.key.ctrl-c") or self.sim.find(label="Control C", kind="Button")
                if pinned:
                    self.sim.tap_el(pinned[0]); time.sleep(0.5)
                self.hide_keyboard()
            except Exception:
                pass

    def _term_keys(self):
        self.open_seed_workspace()
        term = self.seed["term1"]
        notes, problems = [], []
        self.focus_terminal()
        # Each scrolling key is revealed (the key bar scrolled) BEFORE anything is typed
        # on the line. ^C is pinned (design/terminal B2): one direct tap, no scrolling.
        self.keybar_pinned("Control C")
        self.sim.softtype("sleep 300\n")
        time.sleep(1.5)
        self.keybar("Control C")
        self.mac_wait_text(term, "^C", timeout=8)
        notes.append("^C interrupted sleep")
        # Up arrow recalls history; Return runs it again.
        self.keybar_reveal("Up Arrow")
        marker = f"u{random.randint(10000, 99999)}"
        self.sim.softtype(f"echo {marker}\n")
        self.mac_wait_text(term, marker, count=2)
        self.keybar("Up Arrow")
        time.sleep(0.4)
        self.sim.softtype("\n")
        self.mac_wait_text(term, marker, count=4)
        notes.append("Up Arrow recalled the last command")
        # Left arrow edits mid-line: abd, Left, c -> abcd.
        self.keybar_reveal("Left Arrow")
        self.sim.softtype("echo abd")
        self.keybar("Left Arrow")
        self.sim.softtype("c\n")
        self.mac_wait_text(term, "abcd", timeout=8)
        notes.append("Left Arrow moved the cursor (abd -> abcd)")
        # Does scrolling the key bar type the key under the finger?
        line = f"echo k{random.randint(1000, 9999)}"
        self.sim.softtype(line)
        time.sleep(1)
        before = self.mac_screen(term).get("text", "").rstrip().splitlines()[-1]
        self.keybar_reveal("Paste")
        self.keybar_reveal("Left Arrow")
        time.sleep(1)
        after = self.mac_screen(term).get("text", "").rstrip().splitlines()[-1]
        if before != after:
            problems.append(f"scrolling the key bar sent keys: line {before!r} -> {after!r}")
        self.keybar("Control C")
        # Joystick: drag left, the cursor moves.
        js = self.sim.find(label="Cursor joystick")
        if js:
            self.sim.softtype("echo xyz")
            time.sleep(1)
            before = self.mac_screen(term).get("cursor_col")
            cx, cy = js[0].center
            self.sim.drag(cx, cy, cx - 40, cy, duration=0.6, hold=0.4)
            time.sleep(0.8)
            after = self.mac_screen(term).get("cursor_col")
            self.keybar("Control C")
            if not (after is not None and before is not None and after < before):
                problems.append(f"joystick did not move the cursor ({before} -> {after})")
            else:
                notes.append(f"joystick moved the cursor {before}->{after}")
        else:
            problems.append("no joystick on the key bar")
        self.hide_keyboard()
        check(not problems, "; ".join(problems) + " | ok: " + "; ".join(notes))
        return "; ".join(notes)

    def s_term_tui(self):
        self.open_seed_workspace()
        term = self.seed["term1"]
        path = f"/tmp/cmux-mobile-e2e-{self.run_id}.txt"
        self.focus_terminal()
        self.sim.softtype(f"vim -u NONE {path}\n")
        self.mac_wait_text(term, "~", timeout=8, count=5)
        self.sim.softtype("ihello e2e")
        self.keybar("Escape")
        self.sim.softtype(":wq\n")
        deadline = time.time() + 10
        while time.time() < deadline and not os.path.exists(path):
            time.sleep(0.3)
        check(os.path.exists(path) and "hello e2e" in open(path).read(), "vim edit did not reach the Mac file")
        # top as the htop stand-in (htop is not installed on this Mac).
        self.sim.softtype("top\n")
        self.mac_wait_text(term, "Processes", timeout=10)
        shot = self.sim.shot(f"tui-top-{self.run_id}")
        self.sim.softtype("q")
        time.sleep(1)
        marker = f"t{random.randint(10000, 99999)}"
        self.sim.softtype(f"echo {marker}\n")
        self.mac_wait_text(term, marker, count=2)
        self.hide_keyboard()
        return f"vim wrote {path}; top ran and quit; shell responsive after (htop not installed)"

    # design/terminal B1: the top content inset (under the status bar) and the
    # slack allowed for "row 0 at the top": one 16.4 pt row plus OCR box padding.
    TOP_INSET_PT = 62
    TOP_ROW_SLACK_PT = 24

    def s_scrollback(self):
        self.open_seed_workspace()
        term = self.seed["term1"]
        self.hide_keyboard()
        # B1: after `clear` the short session draws from the top inset, with no
        # blank rows above it to scroll into (a drag down only rubber-bands).
        marker = f"B1TOP{self.run_id[-4:]}"
        self.mac_write(term, f"clear; echo {marker}\n")
        self.mac_wait_text(term, marker, timeout=8, count=1)
        time.sleep(1.5)
        top = self.sim.ocr_find(marker, timeout=6)
        self.sim.shot(f"scroll-b1-top-{self.run_id}")
        check(top, f"{marker} not on screen after clear")
        y0 = min(h[1] for h in top)
        check(y0 <= self.TOP_INSET_PT + self.TOP_ROW_SLACK_PT,
              f"after clear the first row is at y {y0:.0f} pt, not at the top inset ({self.TOP_INSET_PT} pt): blank rows above (B1)")
        for _ in range(2):
            self.sim.drag(201, 250, 201, 650, duration=0.4, hold=0.2)
        time.sleep(1.2)
        again = self.sim.ocr_find(marker, timeout=4)
        check(again and abs(min(h[1] for h in again) - y0) <= 4,
              f"a short session scrolled after a drag down (y {y0:.0f} -> {[round(h[1]) for h in again]}): a page of blank rows above (B1)")
        b1 = f"B1: after clear the first row is at y {y0:.0f} pt and a short session does not scroll"
        self.mac_write(term, "clear; seq 1 400\n")
        self.mac_wait_text(term, "400", timeout=8)
        time.sleep(1.5)
        a = self.sim.shot(f"scroll-a-{self.run_id}")
        for _ in range(4):
            self.sim.drag(201, 250, 201, 650, duration=0.4, hold=0.2)
        time.sleep(1)
        b = self.sim.shot(f"scroll-b-{self.run_id}")
        check(open(a, "rb").read() != open(b, "rb").read(), "dragging the terminal did not scroll")
        jump = self.sim.find(contains="bottom") or self.sim.find(contains="Jump")
        if jump:
            self.sim.tap_el(jump[0]); time.sleep(1)
        else:
            for _ in range(5):
                self.sim.drag(201, 650, 201, 150, duration=0.3, hold=0.1)
        return b1 + "; scrolled back through 400 lines" + ("; jump-to-bottom tapped" if jump else "; no jump button found (dragged back)")

    def s_files_links(self):
        self.open_seed_workspace()
        term = self.seed["term1"]
        sample = f"/tmp/cmux-mobile-e2e-{self.run_id}-sample.md"
        open(sample, "w").write(f"# e2e sample {self.run_id}\n\nhello from the Mac\n")
        self.mac_write(term, f"clear; ls -l {sample}; echo https://cmux.com\n")
        self.mac_wait_text(term, "cmux.com", timeout=8, count=1)
        time.sleep(1)
        self.hide_keyboard()
        # The tab title capsule in the bottom toolbar opens the tab's menu.
        title = [e for e in self.sim.find(kind="Button") if e.frame[1] > 780 and e.frame[2] > 150]
        check(title, "no tab title capsule on the terminal toolbar")
        self.sim.tap_el(title[0]); time.sleep(1.2)
        self.sim.tap_q(label="Files and Links", timeout=6)
        time.sleep(2.5)
        notes = []
        if not self.sim.find(contains="Files and Links"):
            notes.append("the Files and Links sheet is invisible to accessibility (VoiceOver cannot use it); read by OCR")
        rows = self.sim.ocr_find(os.path.basename(sample), timeout=6)
        link = self.sim.ocr_find("cmux.com")
        try:
            check(rows, f"Files and Links did not list {sample}")
            # The terminal now draws from the top (design/terminal B1), so its
            # own `ls` line can show above the half sheet: tap the sheet's row.
            rows = sorted(rows, key=lambda o: -o[1])
            x, y, w, h, _ = rows[0]
            self.sim.tap(201, y + h / 2)
            # Valid end states: the file's text, or the refusal view (the Mac shares no
            # folder with this phone, design/terminal M7). Only a blank page fails.
            prev, refusal = None, None
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                prev = self.sim.ocr_find("hello from the Mac")
                if prev:
                    break
                refusal = self.preview_refusal()
                if refusal:
                    break
                time.sleep(0.5)
            self.sim.shot(f"files-preview-{self.run_id}")
            if refusal:
                notes.append(f"preview refused: {refusal}")
                return "; ".join([f"listed {os.path.basename(sample)}; preview shows the refusal (not blank)",
                                  "link listed" if link else "link NOT listed"] + notes)
            if not prev:
                src = self.sim.find(label="Source", kind="RadioButton")
                if src:
                    self.sim.press(*src[0].center, hold=0.1)
                    shown = self.sim.ocr_find("hello from the Mac", timeout=6)
                    notes.append("Source view " + ("shows the text" if shown else "is blank too"))
            check(prev, f"the Preview of {os.path.basename(sample)} stayed blank for 10 s (no text, no refusal view)"
                        + ("; " + "; ".join(notes) if notes else ""))
        finally:
            for _ in range(2):
                self.sim.drag(201, 470, 201, 870, 0.3, 20, 0.1); time.sleep(1)
        return "; ".join([f"listed and previewed {os.path.basename(sample)}", "link listed" if link else "link NOT listed"] + notes)

    # ArtifactPreview's refusal view (CmuxMobileArtifacts ArtifactPreview.refusedIdentifier) and its copy.
    PREVIEW_REFUSED_ID = "artifacts.preview.refused"
    PREVIEW_REFUSAL_TEXT = ("Can't open this file", "Can’t open this file", "isn't sharing any folders",
                            "isn’t sharing any folders")

    def preview_refusal(self):
        """What marks the preview as refused (the AX identifier or its text on screen), else None."""
        if self.sim.find(ident=self.PREVIEW_REFUSED_ID):
            return f"accessibility id {self.PREVIEW_REFUSED_ID}"
        for text in self.PREVIEW_REFUSAL_TEXT:
            if self.sim.find(contains=text):
                return f"text {text!r}"
        # OCR reads either apostrophe; match the words after it.
        for text in ("open this file", "sharing any folders"):
            if self.sim.ocr_find(text):
                return f"text {text!r} (OCR)"
        return None

    def s_image_upload(self):
        self.open_seed_workspace()
        add = self.sim.wait(label="Add attachment", timeout=8)
        check(add, "no Add attachment button on the terminal composer")
        self.sim.press(*add.center, hold=0.1); time.sleep(1.2)
        files = self.sim.find(label="Files", kind="Button")
        photos = self.sim.find(label="Photos", kind="Button")
        check(files or photos, "attachment menu did not open")
        # Photos is drawn under Files but missing from the accessibility tree.
        x, y = photos[0].center if photos else (files[0].center[0], files[0].center[1] + 63)
        self.sim.press(x, y, hold=0.1); time.sleep(3)
        # The system photo picker runs out of process (no accessibility here): fixed spots
        # on the 402x874 pt screen: first library photo, then the checkmark.
        self.sim.tap(200, 412); time.sleep(1)
        self.sim.tap(363, 144); time.sleep(2.5)
        chip = [e for e in self.sim.find(kind="Image") if re.search(r"\.(jpe?g|png|heic)$", e.label or "", re.I)]
        if not chip:
            self.sim.drag(201, 300, 201, 860, 0.3, 20, 0.1)  # dismiss the picker
        check(chip, "no image attached after picking a photo")
        name = chip[0].label
        self.sim.tap_q(ident="terminal.composer.send")
        time.sleep(4)
        errors = [e.label for e in self.sim.tree() if re.search(r"couldn.t send|failed|error", e.label or "", re.I)]
        for e in self.sim.find(kind="Button"):
            if (e.label or "").startswith("Remove "):  # leave the composer clean for later steps
                self.sim.tap_el(e); time.sleep(0.5)
        text = self.mac_screen(self.seed["term1"]).get("text", "")
        flat = text.replace("\n", "").replace("\\ ", " ")
        paths = re.findall(r"(~?/[^❯'\"]*?\.(?:jpe?g|png|heic))", flat, re.I)
        check(not errors, f"the phone reported: {errors[0] if errors else ''}")
        check(paths, f"the phone sent {name} but no path reached the Mac terminal; tail {text[-160:]!r}")
        p = os.path.expanduser(paths[-1].strip())
        check(os.path.exists(p) and os.path.getsize(p) > 0,
              f"the phone typed {paths[-1]} into the shell, but no such file exists on the Mac (upload never happened); "
              f"shell said: {text.strip().splitlines()[-3:] }")
        return f"{name} uploaded to {paths[-1]} ({os.path.getsize(p)} bytes)"

    def s_agent_chat(self):
        raise Blocked("no credit-free REAL harness on this Mac: no local model server (Ollama/LM Studio not installed) "
                      "and cmux-next has no built-in echo harness; Claude/Codex would make paid model calls. "
                      "Streaming, tool calls, Allow/Deny (Face ID), question answer, attachments, diff viewer and artifacts not run.")

    def s_feed(self):
        self.back_to_list()
        self.tab("Feed")
        texts = [str(e.label) for e in self.sim.tree() if e.label and 0 <= e.frame[0] < 402 and 100 < e.frame[1] < 780][:6]
        raise Blocked(f"Feed events come from agent asks; no credit-free harness (see agent_chat). Feed opened: {texts[:4]}")

    def codex_ready(self, term, timeout=60):
        """Waits for Codex's prompt in `term`, accepting the folder trust question."""
        deadline = time.time() + timeout
        text = ""
        while time.time() < deadline:
            text = self.mac_screen(term).get("text", "")
            if "trust" in text.lower() and "1." in text:
                self.mac_write(term, "\r"); time.sleep(2); continue
            if "›" in text and "trust" not in text.lower():
                return text
            time.sleep(1)
        raise Fail(f"Codex never showed its prompt; screen tail: {text[-300:]!r}")

    def codex_prompt(self, term, text):
        # The text, then Return on its own: a Return inside Codex's paste burst is a newline.
        self.mac_write(term, text); time.sleep(1.5)
        self.mac_write(term, "\r")

    def s_feed_terminal(self):
        """Terminal agents in the Feed with the real Codex CLI (model calls: only with
        CMUX_MOBILE_E2E_REAL_CODEX=1). Codex runs in a Mac terminal tab, as the person runs it,
        and reports through its hooks to the daemon's notification ledger. A finished
        turn and an approval it waits on reach the phone's Feed live; the approval is a
        "Needs input" item, and Answer in Terminal opens that terminal tab."""
        if os.environ.get("CMUX_MOBILE_E2E_REAL_CODEX") != "1":
            raise Blocked("needs CMUX_MOBILE_E2E_REAL_CODEX=1 (the real Codex CLI makes model calls)")
        term = self.seed["term2"]
        proj = os.path.expanduser("~/cmux-next-ios-e2e/feedterm-proj")
        os.makedirs(proj, exist_ok=True)
        probe = os.path.join(proj, "feedterm-probe.txt")
        if os.path.exists(probe):
            os.remove(probe)
        self.back_to_list()
        self.tab("Feed")
        video = os.path.join(self.out, f"feed-terminal-{self.run_id}.mp4")
        self.sim.record_start(video)
        notes = []
        try:
            # A read-only sandbox with on-request approvals: writing a file needs the
            # person's approval in the TUI, as a person's cautious setup does.
            # --no-daemon: Codex 0.162's shared app-server daemon runs hooks outside
            # the terminal (no CMUX_TUI_HOOK/SOCKET), so its events never reach the
            # daemon; in-process hooks do (verify notes, feat-cnx-ios-feedterm).
            self.mac_write(term, f"clear; cd {proj} && codex --no-daemon --sandbox read-only --ask-for-approval on-request\n")
            self.codex_ready(term)
            t = time.time()
            self.codex_prompt(term, "Reply with exactly one word: ready")
            done = self.sim.wait(label="Codex", timeout=150)
            if not done:
                ledger = self.mac.cmux("notification", "list", check=False, timeout=20)
                screen = self.mac_screen(term).get("text", "")
                raise Fail(f"no Codex item in the Feed 150 s after Codex's turn; Mac ledger: "
                           f"{(ledger.stdout or ledger.stderr)[-400:]!r}; screen tail: {screen[-300:]!r}")
            notes.append(f"finished turn in the Feed after {time.time()-t:.1f} s")
            self.sim.shot(f"feed-terminal-finished-{self.run_id}")
            t = time.time()
            self.codex_prompt(term, "Create the file feedterm-probe.txt in this folder by running: touch feedterm-probe.txt (ask me for approval if the sandbox blocks it)")
            ask = self.sim.wait(label="Needs input", timeout=150)
            screen = self.mac_screen(term).get("text", "")
            check(ask, f"no Needs input item 150 s after asking Codex to run a command; Mac screen tail: {screen[-300:]!r}")
            notes.append(f"approval as Needs input after {time.time()-t:.1f} s")
            self.sim.shot(f"feed-terminal-needs-input-{self.run_id}")
            time.sleep(2)
            opened = None
            for _ in range(3):  # a tap while the list still settles can be dropped
                self.sim.tap_q(ident="feed.terminal.open")
                opened = self.sim.wait(ident="terminal.composer.field", timeout=8)
                if opened:
                    break
            check(opened, "Answer in Terminal did not open the terminal tab")
            time.sleep(3)
            self.sim.shot(f"feed-terminal-opened-{self.run_id}")
            notes.append("Answer in Terminal opened the terminal tab")
        finally:
            self.sim.record_stop()
            # Decline the approval and leave Codex.
            self.mac_write(term, "\x1b"); time.sleep(1)
            self.mac_write(term, "\x03"); time.sleep(0.5); self.mac_write(term, "\x03")
        return {"notes": "; ".join(notes) + f"; video {os.path.relpath(video, self.out)}"}

    def s_chief(self):
        self.back_to_list()
        self.tab("Home")
        self.sim.tap_q(ident="home.chief")
        t = time.time()
        loaded = None
        while time.time() - t < 25:
            els = self.sim.tree()
            if not self.sim.find(ident="conversation.initialLoading", elements=els) and self.sim.find(ident="conversation.transcript", elements=els):
                loaded = time.time() - t
                break
            time.sleep(0.5)
        self.sim.shot(f"chief-{self.run_id}")
        bubbles = [e.label for e in self.sim.find(ident="conversation.transcript")] if loaded else []
        engine = self.mac.cmux("chief", "engine", check=False, timeout=30)
        eng = (engine.stdout or engine.stderr).strip()[:200]
        model = [e.label for e in self.sim.tree() if re.search(r"model|sonnet|opus|gpt|haiku", e.label or "", re.I) and 0 <= e.frame[0] < 402]
        self.back_to_list()
        check(loaded is not None, f"Chief never loaded: the conversation spinner (conversation.initialLoading) was still up after 25 s; "
                                  f"no model picker on the screen; Mac CLI `cmux chief engine`: {eng}")
        raise Blocked(f"Chief loaded in {loaded:.1f} s; send/receive not run (a paid model call). Model controls: {model[:3] or 'none'}; Mac engine: {eng}")

    def settings_find(self, timeout=8, **q):
        """Finds a row on the Settings page, scrolling up then down."""
        for d in [(250, 750)] * 3 + [(650, 250)] * 6:
            e = self.sim.find(**q)
            if e and 100 < e[0].center[1] < 780:
                return e[0]
            self.sim.drag(201, d[0], 201, d[1], 0.4, 20, 0.2); time.sleep(0.6)
        return None

    def open_transport_page(self):
        """Settings > Transport (a page since the Settings redesign; the rig used to look for an inline picker)."""
        self.tab("Settings")
        if self.sim.find(ident="settings.transport.webrtc"):
            return
        for _ in range(3):  # a tap right after the tab switch can be dropped
            row = self.settings_find(contains="Transport", kind="Button")
            check(row, "no Transport row in Settings")
            self.sim.tap_el(row)
            if self.sim.wait(ident="settings.transport.webrtc", timeout=4):
                return
        raise Fail("the Transport page did not open")

    def close_transport_page(self):
        back = [e for e in self.sim.find(kind="Button") if e.label == "Back" or e.ident == "BackButton"]
        if back:
            self.sim.tap_el(back[0]); time.sleep(0.8)

    def settings_transport(self, name):
        self.tab("Settings")
        cur = self.settings_find(contains="Transport,", kind="Button")
        if cur and cur.label.endswith(name):
            return 0.0
        self.open_transport_page()
        kind = {"WebRTC": "webrtc", "WireGuard": "wireguard"}[name]
        item = self.sim.find(ident=f"settings.transport.{kind}")[0]
        self.sim.tap_el(item)
        t = time.time()
        self.close_transport_page()
        self.tab("Workspaces")
        lab = ""
        while time.time() - t < 30:
            lab = self.link_status()
            if "Connected" in lab and name.lower() in lab.lower():
                return time.time() - t
            time.sleep(0.3)
        raise Fail(f"{name}: link not Connected over {name} after 30 s ({lab!r})")

    def term_roundtrip(self):
        self.open_seed_workspace()
        m = self.current_tab_marker()
        check(m is not None, "terminal input did not reach the Mac")
        self.back_to_list()

    def s_transport(self):
        a = self.settings_transport("WireGuard")
        self.term_roundtrip()
        b = self.settings_transport("WebRTC")
        self.term_roundtrip()
        return {"notes": f"WireGuard Connected in {a:.1f} s, back to WebRTC in {b:.1f} s; terminal input worked on both",
                "metric_wg_switch_s": round(a, 2), "metric_webrtc_switch_s": round(b, 2)}

    def relay_toggle(self, want, ident="settings.transport.relayOnly"):
        """Sets a Settings > Transport > Developer toggle (Relay only, or Block UDP with
        `ident="settings.transport.blockUDP"`) to `want` ("1"/"0"); returns (before, after)."""
        self.open_transport_page()
        e = self.sim.wait(ident=ident, timeout=5)
        check(e, f"no {ident} toggle on Settings > Transport")
        before = e.value
        for _ in range(3):
            if e.value == want:
                break
            self.sim.press(e.frame[0] + e.frame[2] - 40, e.center[1], hold=0.1)
            time.sleep(1.2)
            e = self.sim.find(ident=ident)[0]
        after = e.value
        self.close_transport_page()
        return before, after

    def mac_path(self, since):
        """The rig Mac's label of the phone's link path since `since` (cmux-mobile-host's log:
        `link up ... path=` and `link path changed path=`), the latest one."""
        path = os.path.join(self.mac.hostd_state, "cmux-mobile-host.log")
        last = None
        if os.path.exists(path):
            for line in open(path, errors="replace"):
                if ("link up" in line or "link path changed" in line) and "path=" in line:
                    m = re.search(r"path=(\w+)", line)
                    if m:
                        last = m.group(1)
        return last

    def wait_status(self, want, timeout=40):
        """Waits for a 'Connected' link line containing `want`; returns (line, seconds, seen)."""
        t = time.time()
        self.tab("Workspaces")
        seen = []
        while time.time() - t < timeout:
            lab = self.link_status()
            if lab and (not seen or seen[-1][1] != lab):
                seen.append((round(time.time() - t, 1), lab))
            if "Connected" in lab and want(lab):
                return lab, time.time() - t, seen
            time.sleep(0.4)
        return None, time.time() - t, seen

    def browser_over_link(self):
        """Opens a browser workspace from the phone (hold New Workspace > New Browser
        Workspace), loads example.com and waits for the page on the phone's screen."""
        self.back_to_list()
        new = self.sim.wait(ident="workspaces.new", timeout=10)
        check(new, "no New Workspace button")
        self.sim.long_press(*new.center, seconds=1.0); time.sleep(1.0)
        item = self.sim.find(contains="Browser")
        if not item:
            raise Blocked("this Mac build offers no browser workspace in the hold menu")
        before = {w["id"] for w in self.mac.cmux("workspace", "list", json_out=True)}
        t = self.sim.tap_el(item[0])
        bar = self.sim.wait(contains="Search or enter website", timeout=20)
        check(bar, "the browser workspace showed no address bar in 20 s")
        self.sim.tap_el(bar); time.sleep(0.8)
        self.sim.dismiss_keyboard_intro()
        self.sim.softtype("example.com\n")
        found = self.sim.ocr_find("Example Domain", timeout=25)
        self.sim.shot(f"browser-turn-tls-{self.run_id}")
        dt = time.time() - t
        now = self.mac.cmux("workspace", "list", json_out=True)
        for w in now:
            if w["id"] not in before:
                self.mac.cmux("workspace", w["id"], "close", check=False)
        self.back_to_list()
        check(found, "example.com did not render on the phone in 25 s")
        return round(dt, 1)

    def s_turn_paths(self):  # noqa: C901 - one live scenario, two modes
        """WireGuard over TURN on the real link, typed on the phone: Relay only (TURN
        over UDP), then Block UDP (no plain UDP, no TURN over UDP: TURN over TLS on
        443). Each: the link line, the Mac's label, a terminal round trip, keystroke
        echo latency; over TLS also a browser tab."""
        from latency import Latency
        wg = self.settings_transport("WireGuard")
        out = {"metric_wg_switch_s": round(wg, 2)}
        notes = []
        modes = (("turn_udp", "settings.transport.relayOnly", lambda lab: "TURN)" in lab and "TLS" not in lab),
                 ("turn_tls", "settings.transport.blockUDP", lambda lab: "TURN over TLS" in lab))
        try:
            for mode, ident, want in modes:
                since = time.time()
                b, a = self.relay_toggle("1", ident)
                check(a == "1", f"{ident} did not turn on ({b} -> {a})")
                st, dt, seen = self.wait_status(want)
                check(st, f"{mode}: never 'Connected' on the expected path in 40 s; status sequence {seen[:6]}")
                # Typed on the phone: a command through the composer, then
                # keystroke echo measured from the screen recording, both in
                # the seeded terminal without leaving it.
                self.open_seed_workspace()
                check(self.current_tab_marker() is not None, f"{mode}: terminal input did not reach the Mac")
                stay = _InTerminal(self)
                lat = Latency(stay, os.path.join(self.out, f"latency-{mode}"), self.log, 12)
                lat.keystroke_echo(False)
                echo = lat.metrics.get("keystroke_echo_idle", {})
                browser = self.browser_over_link() if mode == "turn_tls" else None
                mac = self.mac_path(since)
                out[f"metric_{mode}_connect_s"] = round(dt, 2)
                out[f"{mode}_status"] = st
                out[f"{mode}_mac_path"] = mac
                out[f"metric_{mode}_echo_median_ms"] = echo.get("median_ms")
                out[f"metric_{mode}_echo_p95_ms"] = echo.get("p95_ms")
                if browser is not None:
                    out["metric_turn_tls_browser_s"] = browser
                notes.append(f"{mode}: '{st}' in {dt:.1f} s, Mac path {mac}, keystroke echo {echo.get('median_ms')} ms median"
                             f" / {echo.get('p95_ms')} ms p95" + (f", example.com rendered in {browser} s" if browser else ""))
                self.relay_toggle("0", ident)
        finally:
            for _, ident, _ in modes:
                try:
                    self.relay_toggle("0", ident)
                except Exception:
                    pass
        return {"notes": "; ".join(notes)} | out

    def s_relay_only(self):
        b, a = self.relay_toggle("1")
        check(a == "1", f"Relay only did not turn on ({b} -> {a})")
        t = time.time()
        self.tab("Workspaces")
        seen, st = [], None
        while time.time() - t < 40:
            lab = self.link_status()
            if lab and (not seen or seen[-1][1] != lab):
                seen.append((round(time.time() - t, 1), lab))
            if "Connected" in lab and re.search(r"relay|turn", lab, re.I):
                st = lab; break
            time.sleep(0.4)
        dt = time.time() - t
        ok = st is not None
        if ok:
            self.term_roundtrip()
        b2, a2 = self.relay_toggle("0")
        check(ok, f"relay-only: never 'Connected' via relay/TURN in 40 s; status sequence {seen[:6]}")
        return {"notes": f"'{st}' in {dt:.1f} s; terminal worked over the relay; toggled back off (value {a2})",
                "metric_relay_connect_s": round(dt, 2)}

    def s_sign_out_in(self):
        self.tab("Settings")
        for _ in range(6):
            if self.sim.find(ident="settings.logout"):
                break
            self.sim.drag(201, 650, 201, 250, duration=0.4, hold=0.2)
        lo = self.settings_find(ident="settings.logout")
        check(lo, "no Log out row in Settings")
        self.sim.tap_el(lo)
        time.sleep(1.2)
        conf = [e for e in self.sim.find(label="Log out", kind="Button") if e.ident != "settings.logout"]
        check(conf, "no Log out confirmation")
        self.sim.press(*conf[-1].center, hold=0.1)
        check(self.sim.wait(label="Continue with email", kind="Button", timeout=20), "sign-out did not return to Welcome")
        self.s_sign_in()
        self.s_choose_space()
        self.s_mac_discovered()
        return "signed out to Welcome, signed back in and relinked the rig Mac"

    # ---- persistence (verify/persistence.md) -------------------------------
    def paired_phones(self):
        """The rig Mac's approved phones ({id, identityKey, approvalKey, pairedAt}) from its
        per-user paired-devices.json (written by the app, read-only here)."""
        path = os.path.join(self.mac.hostd_state, "paired-devices.json")
        try:
            return json.load(open(path)).get("devices", [])
        except (OSError, ValueError):
            return []

    def sign_out(self):
        self.back_to_list()
        self.tab("Settings")
        for _ in range(6):
            if self.sim.find(ident="settings.logout"):
                break
            self.sim.drag(201, 650, 201, 250, duration=0.4, hold=0.2)
        lo = self.settings_find(ident="settings.logout")
        check(lo, "no Log out row in Settings")
        self.sim.tap_el(lo)
        time.sleep(1.2)
        conf = [e for e in self.sim.find(label="Log out", kind="Button") if e.ident != "settings.logout"]
        check(conf, "no Log out confirmation")
        self.sim.press(*conf[-1].center, hold=0.1)
        check(self.sim.wait(label="Continue with email", kind="Button", timeout=20), "sign-out did not return to Welcome")

    def s_persist_approval(self):
        """Sign out and back in: the same phone (device id, keys) reconnects with no new
        Mac approval. Then Settings > Devices > Remove This iPhone from My Macs: the Mac
        forgets it, and the next connection asks the Mac again (the rig's DEBUG seed
        answers that ask, so a new approval shows as a new paired-devices entry)."""
        video = os.path.join(self.out, "persist-approval.mp4")
        self.sim.record_start(video)
        try:
            result = self._persist_approval()
        finally:
            self.sim.record_stop()
        result["video"] = video
        return result

    def _persist_approval(self):
        before = self.paired_phones()
        check(before, "the rig Mac lists no approved phone before sign-out (pairing never ran?)")
        self.sim.shot("persist-1-paired")
        self.sign_out()
        self.sim.shot("persist-2-signed-out")
        self.s_sign_in()
        landed = "setup" if self.sim.find(ident="setup.teams.choose") or self.sim.find(ident="setup.teams.create") \
            or self.sim.find(contains="Connect your Mac") else "Workspaces"
        self.s_choose_space()
        self.s_mac_discovered()
        self.sim.shot("persist-3-reconnected")
        after = self.paired_phones()
        check(after == before, f"the Mac's approved phones changed across sign-out/sign-in: {before} -> {after}")
        # The explicit removal.
        self.back_to_list()
        self.tab("Settings")
        dev = self.settings_find(ident="settings.devices")
        check(dev, "no Devices row in Settings")
        self.sim.tap_el(dev); time.sleep(2.5)
        rm = self.settings_find(ident="settings.removeThisPhone")
        check(rm, "no 'Remove This iPhone from My Macs' on the Devices page")
        self.sim.shot("persist-4-devices")
        self.sim.tap_el(rm); time.sleep(1.2)
        conf = self.sim.find(label="Remove", kind="Button")
        check(conf, "no Remove confirmation")
        self.sim.shot("persist-5-confirm")
        self.sim.press(*conf[-1].center, hold=0.1)
        t, replaced = time.time(), None
        old = {(d["id"], d["identityKey"]) for d in before}
        while time.time() - t < 90:
            now = self.paired_phones()
            ids = {d["id"] for d in before}
            fresh = [d for d in now if d["id"] in ids and (d["id"], d["identityKey"]) not in old]
            if fresh:
                replaced = (time.time() - t, fresh[0])
                break
            time.sleep(1)
        check(replaced, f"no new approval within 90 s of the removal: {self.paired_phones()}")
        self.back_to_list()
        dt = self.wait_connected(60)
        self.sim.shot("persist-6-reapproved")
        check(dt is not None, f"after the new approval the link never reached Connected ({self.link_status()!r})")
        return {"notes": f"sign-out/in kept {len(before)} approval(s) unchanged (same device id, keys, pairedAt); "
                         f"sign-in landed on {landed}; removal: the Mac asked again and approved new keys for "
                         f"{replaced[1]['id'][:8]} in {replaced[0]:.1f} s; link Connected again"}

    def link_status(self):
        """The rig Mac's link line. Old list: the status row. Redesigned list: the
        subtitle of the rig Mac in the Filter menu (read by OCR; AX has only the name)."""
        s = self.sim.find(ident="mac-link-status")
        if s:
            return s[0].label or ""
        f = self.sim.find(ident="workspaces.filter")
        if not f:
            return ""
        # The Filter button's value carries the chosen Mac's presence and link
        # line (round 7); the menu-and-OCR read below returned "" on the rig.
        v = f[0].value or ""
        if ", " in v and any(k in v for k in ("Online", "Offline", "Last seen", "Connected", "Connecting")):
            return v.split(", ", 1)[1]
        self.sim.press(*f[0].center, hold=0.1)
        # The rig Mac's row by its device id (names repeat: "Aziz's MacBook Pro (1952)").
        item = self.sim.wait(ident=f"workspaces.filter.{self.device_id}", timeout=4)
        text = ""
        if item:
            x, y, w, h = item.frame
            # The row's gray subtitle is drawn after the menu's open animation: OCR
            # read too early sees only the title (every redesigned-list run since the
            # names grew a tag and the subtitle wrapped to three lines).
            for _ in range(3):
                time.sleep(0.8)
                text = " ".join(o[4] for o in self.sim.ocr() if y - 2 <= o[1] <= y + h and o[0] >= x - 4)
                if "Online" in text or "Last seen" in text or "Offline" in text:
                    break
        self.sim.tap(60, 450)  # outside the menu: dismiss without choosing
        time.sleep(0.6)
        return text

    def choose_mac(self):
        """Redesigned list: Filter > the rig Mac. Returns the tap time."""
        f = self.sim.wait(ident="workspaces.filter", timeout=10)
        check(f, "no Filter button on Workspaces")
        self.sim.press(*f.center, hold=0.1)
        item = self.sim.wait(ident=f"workspaces.filter.{self.device_id}", timeout=6)
        check(item, f"the Filter menu does not list the rig Mac ({self.device_id})")
        return self.sim.press(*item.center, hold=0.1)

    def wait_connected(self, timeout):
        t = time.time()
        while time.time() - t < timeout:
            if "Connected" in self.link_status():
                return time.time() - t
            time.sleep(0.25)
        return None

    def s_background(self):
        self.back_to_list()
        check(self.wait_connected(20) is not None, "not connected before backgrounding")
        self.sim.home()
        time.sleep(45)
        t = self.sim.launch(BUNDLE, terminate=False)  # the running app back to the foreground
        dt = self.wait_connected(30)
        check(dt is not None, f"no Connected within 30 s of foreground ({self.link_status()})")
        self.term_roundtrip()
        return {"notes": f"45 s in background; Connected {dt:.2f} s after foreground; terminal input reached the Mac",
                "metric_foreground_reconnect_s": round(dt, 2)}

    def s_mac_restart(self):
        self.back_to_list()
        self.mac.quit()
        t = time.time()
        off = None
        while time.time() - t < 40:
            st = self.link_status()
            if st and "Connected" not in st:
                off = time.time() - t; break
            time.sleep(0.5)
        offline_label = self.link_status()
        self.mac.launch()
        self.mac.wait_hostd(120)
        t2 = time.time()
        dt = self.wait_connected(90)
        check(off is not None, f"phone kept showing Connected for 40 s after the Mac quit ({offline_label})")
        check(dt is not None, "phone did not reconnect within 90 s of the Mac relaunch")
        self.term_roundtrip()
        return {"notes": f"offline shown {off:.1f} s after quit ('{offline_label}'); reconnected {dt:.1f} s after cmux-mobile-host was back; terminal OK",
                "metric_mac_relaunch_reconnect_s": round(dt, 2)}

    def s_device_removal(self):
        """Settings > Paired Macs > swipe the rig Mac > Remove. It must leave the phone's
        Mac list and stay gone (the rig Mac keeps running with iPhone connections on).
        The row is found by the rig Mac's device id, never by name: the dev account
        lists several Macs with the same name."""
        check(self.device_id, "the rig Mac has no cmux-mobile-host device id; refusing to pick a Mac to remove by name")
        row_id = f"settings.pairedMacs.{self.device_id}"
        self.back_to_list()
        self.tab("Settings")
        pm = self.settings_find(contains="Paired Macs", kind="Button")
        check(pm, "no Paired Macs row in Settings")
        self.sim.tap_el(pm); time.sleep(2.5)
        row = self.settings_find(ident=row_id)
        check(row, f"the rig Mac (device {self.device_id}) is not in Paired Macs")
        y = row.center[1]
        self.sim.drag(370, y, 120, y, 0.4, 20, 0.2); time.sleep(1)
        rm = self.sim.wait(label="Remove", kind="Button", timeout=4)
        check(rm, "no Remove action on the row's trailing swipe")
        self.sim.tap_el(rm); time.sleep(1.2)
        conf = [e for e in self.sim.find(label="Remove", kind="Button")]
        check(conf, "no Remove confirmation")
        msg = [e.label for e in self.sim.tree() if "leaves the Mac list" in (e.label or "")]
        self.sim.press(*conf[-1].center, hold=0.1)
        t = time.time()
        gone = None
        while time.time() - t < 20:
            if not self.sim.find(ident=row_id):
                gone = time.time() - t
                break
            time.sleep(1)
        err = [e.label for e in self.sim.tree() if "Couldn't remove" in (e.label or "")]
        check(not err, f"removal failed: {err}")
        check(gone is not None, "the rig Mac stayed in Paired Macs 20 s after Remove")
        time.sleep(30)
        self.back_to_list()
        f = self.sim.find(ident="workspaces.filter")
        back = None
        if f:
            self.sim.press(*f[0].center, hold=0.1)
            back = self.sim.wait(ident=f"workspaces.filter.{self.device_id}", timeout=3)
            self.sim.tap(60, 450)
        check(back is None, "the removed rig Mac came back in the phone's Mac list within 30 s (cmux on it is still running)")
        return {"notes": f"removed in {gone:.1f} s; still gone 30 s later; dialog: {msg[:1]}"}

    def mac_name(self):
        return None

    # ------------------------------------------------------------------ plan
    def plan(self):
        return [
            ("fresh_install", "Fresh install and Welcome", "wsdesign", self.s_fresh_install),
            ("sign_in", "Sign in (dev account, email 42)", "prodinfra", self.s_sign_in),
            ("choose_space", "Choose team / personal, setup steps", "wsdesign", self.s_choose_space),
            ("mac_discovered", "Mac discovered, no false 'No workspaces'", "fastconn", self.s_mac_discovered),
            ("workspace_list", "Workspaces list filtered by Mac matches the Mac", "dataflow", self.s_workspace_list),
            ("create_workspace", "Create workspace (instant)", "dataflow", self.s_create_workspace),
            ("open_workspace", "Open workspace", "wsdesign", self.s_open_workspace),
            ("last_tab_restore", "Last-tab restore and tab grid", "wsdesign", self.s_last_tab_restore),
            ("relaunch_restore", "Relaunch restores the tab and attaches", "wsdesign", self.s_relaunch_restore),
            ("term_direct", "Terminal: direct typing (soft keyboard)", "termlive", self.s_term_direct),
            ("term_composer", "Terminal: composer", "termlive", self.s_term_composer),
            ("scrollback_history", "Terminal: the phone reaches the Mac's first line of history", "termlive", self.s_scrollback_history),
            ("composer_bottom_pin", "Terminal: the last row rests above the composer", "termlive", self.s_composer_bottom_pin),
            ("composer_submit", "Terminal: Send submits (paste, then Return)", "termlive", self.s_composer_submit),
            ("tab_switch_last_row", "Terminal: the last row after a tab switch", "termlive", self.s_tab_switch_last_row),
            ("codex_scroll_hold", "Terminal: scrolled up during a Codex stream holds (real Codex)", "termlive", self.s_codex_scroll_hold),
            ("joystick_paste_close", "Terminal: joystick flick and hold, paste control, close confirmation", "termlive", self.s_joystick_paste_close),
            ("reattach_no_jumps", "Terminal: a reattach with long history does not pass through old rows", "termlive", self.s_reattach_no_jumps),
            ("no_resize_on_scroll", "Terminal: scrolling up never resizes the PTY", "termlive", self.s_no_resize_on_scroll),
            ("codex_reset_watch", "Terminal: Codex working, untouched: no resets or resizes (real Codex)", "termlive", self.s_codex_reset_watch),
            ("scroll_to_bottom_stable", "Terminal: scrolling into the bottom never flashes another region", "termlive", self.s_scroll_to_bottom_stable),
            ("scroll_while_streaming", "Terminal: scrolling while output streams is smooth and stays put", "termlive", self.s_scroll_while_streaming),
            ("keybar_swipe_no_back", "Terminal: a swipe on the key bar never swipes back", "termlive", self.s_keybar_swipe_no_back),
            ("shell_pull_keyboard_up", "Terminal: pull-down with the keyboard up reaches history", "termlive", self.s_shell_pull_keyboard_up),
            ("tui_quit_keyboard_up", "Terminal: quit a TUI with the keyboard up", "termlive", self.s_tui_quit_keyboard_up),
            ("term_keys", "Terminal: ^C, arrows, joystick", "termlive", self.s_term_keys),
            ("term_tui", "Terminal: vim and top TUI", "termlive", self.s_term_tui),
            ("term_scrollback", "Terminal: scrollback", "termlive", self.s_scrollback),
            ("files_links", "Terminal: Files and Links preview", "termlive", self.s_files_links),
            ("image_upload", "Terminal: image upload", "termlive", self.s_image_upload),
            ("agent_chat", "Agent chat (stream, tools, approvals, question, attachments, diff, artifacts)", "approvals", self.s_agent_chat),
            ("feed", "Feed events and inline answer", "approvals", self.s_feed),
            ("feed_terminal", "Feed: a terminal agent's events (real Codex), Needs input opens the tab", "feedterm", self.s_feed_terminal),
            ("chief", "Chief: real Mac conversation, send/receive, model", "chieflive", self.s_chief),
            ("transport", "Transport WebRTC <-> WireGuard", "fastconn", self.s_transport),
            ("relay_only", "Relay only", "fastconn", self.s_relay_only),
            ("turn_paths", "WireGuard over TURN: UDP, then TLS with UDP blocked", "fastconn", self.s_turn_paths),
            ("sign_out_in", "Sign out and back in", "prodinfra", self.s_sign_out_in),
            ("persist_approval", "Sign-out keeps the Mac approval; Remove This iPhone asks again", "persist", self.s_persist_approval),
            ("background", "Background 45 s / foreground reconnect", "fastconn", self.s_background),
            ("mac_restart", "Mac app quit / relaunch, reconnect", "machost", self.s_mac_restart),
            ("device_removal", "Device removal", "machost", self.s_device_removal),
        ]

    LAST = ("device_removal",)  # run by e2e.py after the latency metrics (it unlinks the Mac)

    def run(self, only=None, skip=(), last=False):
        if not last:
            self.seed_mac()
        for sid, title, owner, fn in self.plan():
            if (sid in self.LAST) != last:
                continue
            if (only and sid not in only) or sid in skip:
                continue
            try:
                self.step(sid, title, owner, fn)
            except Exception as e:  # the rig itself failed around a step: record it and go on
                self.results.append({"id": sid, "title": title, "owner": owner, "status": "fail",
                                     "notes": f"rig error around the step: {e}"[:400], "seconds": 0})
        return self.results


class _InTerminal:
    """The journey as the latency probe sees it, already in the seeded terminal:
    returning to the list and reopening it are no-ops (the list's sheet
    handling taps an off-screen row on the current app)."""

    def __init__(self, journey):
        self._j = journey

    def back_to_list(self):
        pass

    def open_seed_workspace(self):
        pass

    def __getattr__(self, name):
        return getattr(self._j, name)
