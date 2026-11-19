#!/usr/bin/env python3
"""Real-user stress loop for the cmux NEXT iPhone app, on top of the e2e rig.

One hidden, tagged cmux NEXT Mac app (verify/e2e/mac.py) and one headless
simulator running the iPhone app. A load thread grows the Mac's work every
cycle: new workspaces, each with one Codex agent, alternating a terminal agent
(the Codex CLI in a terminal tab) and a GUI agent (a Codex agent chat tab);
a feed thread posts notifications all the time, and the agents' own hooks add
theirs. Each cycle the phone walks every user path in PATHS as a person
would (AXe touches, the soft keyboard), with a screen recording, and every
path is judged: did its screen come up, how long did it take, did the app
hang (empty accessibility tree, sampled) or die. A sampler records the
phone app's and the Mac app's CPU and memory.

Only Codex agents are started (the user's rule for this loop). Codex reaches
its model through the fleet's subrouter (~/.codex/config.toml on the mini).

    python3 stress.py --mac-app PATH --ios-app PATH [--cycles N] [--minutes-per-cycle M]
        [--start-agents N] [--add-per-cycle N] [--max-agents N] [--feed-interval S]
        [--paths a,b] [--out DIR] [--keep]

Evidence: OUT/cycles.jsonl (one line per path run), OUT/metrics.jsonl (one
sample every 5 s), OUT/load.jsonl (each workspace and agent started),
OUT/shots/, OUT/video/cycle-N.mp4, OUT/hangs/. render_report.py turns OUT
into the HTML log.
"""
import argparse
import datetime
import json
import os
import random
import re
import subprocess
import sys
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../e2e"))
from sim import Sim  # noqa: E402
from mac import Mac, pb, refuse_other_rigs  # noqa: E402
from journey import Journey, Fail, Blocked, check, BUNDLE  # noqa: E402

DEVICE = "iPhone 17 Pro"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-5"

# Prompts that keep a Codex agent busy for a while and make it write files,
# run commands and stream text, the way a person's agents do.
TASKS = [
    "Build a small Python CLI in this folder that parses a CSV of expenses and prints monthly totals. "
    "Write it in steps: the parser, then tests with unittest, then run the tests and fix failures. Explain each step briefly.",
    "Write a markdown guide in this folder (GUIDE.md) on how TCP congestion control works, with sections for slow start, "
    "congestion avoidance, fast retransmit and BBR. Then write a short quiz with answers at the end.",
    "Create a tiny static website in this folder (index.html, style.css, app.js) for a todo list that saves to localStorage. "
    "Then review your own code and list three improvements, and apply them.",
    "In this folder, implement a Rust-like Result type in TypeScript (result.ts) with map, andThen and unwrapOr, plus examples. "
    "Then write a README explaining it.",
    "Write a Python script that generates the first 300 prime numbers, prints them in rows of 10, and then prints statistics "
    "about the gaps between them. Run it and show the output.",
    "Investigate this folder (it may be empty), then scaffold a Go HTTP server with /health and /items endpoints, an in-memory store, "
    "and tests. Run go vet if Go is installed; otherwise explain what you would run.",
]
FOLLOW_UPS = ["keep going", "now add error handling", "summarize what you did so far in 5 bullets",
              "make it faster", "add one more test", "explain the hardest part"]


def now():
    return datetime.datetime.now().strftime("%H:%M:%S")


class Recorder:
    def __init__(self, out):
        self.out = out
        self.lock = threading.Lock()
        os.makedirs(out, exist_ok=True)
        self.logf = open(os.path.join(out, "run.log"), "a")

    def log(self, msg):
        line = f"{now()} {msg}"
        with self.lock:
            print(line, flush=True)
            self.logf.write(line + "\n")
            self.logf.flush()

    def jsonl(self, name, rec):
        rec = dict(rec, t=round(time.time(), 2))
        with self.lock:
            with open(os.path.join(self.out, name), "a") as f:
                f.write(json.dumps(rec, default=str) + "\n")


class Load:
    """Grows the Mac's work: workspaces with Codex agents (terminal and GUI, alternating), and Feed events."""

    def __init__(self, mac, rec, codex_bin, node_bin, proj_root, feed_interval):
        self.mac, self.rec = mac, rec
        self.codex = codex_bin
        self.path = f"{os.path.dirname(codex_bin)}:{node_bin}:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        self.proj_root = proj_root
        self.feed_interval = feed_interval
        self.agents = []  # {"kind","ws","name","term"|"chat","started"}
        self.stop = threading.Event()
        self.feed_count = 0
        self.errors = []

    def counts(self):
        t = sum(1 for a in self.agents if a["kind"] == "terminal")
        return {"agents": len(self.agents), "terminal": t, "gui": len(self.agents) - t, "feed_posted": self.feed_count}

    def add_agent(self):
        n = len(self.agents) + 1
        kind = "terminal" if n % 2 == 1 else "gui"
        name = f"stress-{n:03d}-{'term' if kind == 'terminal' else 'chat'}"
        proj = os.path.join(self.proj_root, name)
        os.makedirs(proj, exist_ok=True)
        task = TASKS[(n - 1) % len(TASKS)]
        t0 = time.time()
        try:
            ws = self.mac.cmux("workspace", "create", "--name", name, json_out=True)["value"]
            rec = {"kind": kind, "ws": ws["workspace_id"], "name": name, "started": t0, "task": task[:80]}
            if kind == "terminal":
                term = ws["terminal_id"]
                # Half of the terminal agents ask for approval (a "Needs input" Feed item), as a cautious person runs it.
                policy = "--ask-for-approval on-request --sandbox read-only" if (n // 2) % 2 == 0 else \
                    "--ask-for-approval never --sandbox workspace-write"
                self.mac.cmux("terminal", term, "write", "--text",
                              f"clear; cd {proj} && PATH={self.path} {self.codex} --no-daemon {policy}\n")
                rec["term"] = term
                rec["policy"] = policy
                threading.Thread(target=self._codex_first_prompt, args=(term, task), daemon=True).start()
            else:
                r = self.mac.cmux("agents", "chat", "new", "--workspace", ws["workspace_id"], "--harness", "codex",
                                  "--cwd", proj, "--name", name, "--", task, json_out=True, timeout=120)
                rec["chat"] = (r or {}).get("chat_id") or (r or {}).get("id") or json.dumps(r)[:200]
            rec["setup_s"] = round(time.time() - t0, 2)
            self.agents.append(rec)
            self.rec.jsonl("load.jsonl", rec)
            self.rec.log(f"load: +{kind} agent {name} ({rec['setup_s']} s); now {self.counts()}")
        except Exception as e:  # a failed start is a finding, the loop goes on
            err = {"kind": kind, "name": name, "error": str(e)[:400]}
            self.errors.append(err)
            self.rec.jsonl("load.jsonl", err)
            self.rec.log(f"load: FAILED to start {kind} agent {name}: {str(e)[:200]}")

    def _codex_first_prompt(self, term, task):
        deadline = time.time() + 90
        while time.time() < deadline and not self.stop.is_set():
            try:
                text = self.mac.cmux("terminal", term, "screen", "read", json_out=True, timeout=20).get("text", "")
            except Exception:
                text = ""
            if "trust" in text.lower() and "1." in text:
                self.mac.cmux("terminal", term, "write", "--text", "\r", check=False)
                time.sleep(2)
                continue
            if "›" in text and "trust" not in text.lower():
                self.mac.cmux("terminal", term, "write", "--text", task, check=False)
                time.sleep(1.5)
                self.mac.cmux("terminal", term, "write", "--text", "\r", check=False)
                return
            time.sleep(1.5)
        self.rec.log(f"load: Codex in {term} never showed its prompt")

    def nudge(self):
        """A person checks on a few agents: a follow-up to a random idle one."""
        if not self.agents:
            return
        a = random.choice(self.agents)
        text = random.choice(FOLLOW_UPS)
        try:
            if a["kind"] == "terminal":
                self.mac.cmux("terminal", a["term"], "write", "--text", text, check=False)
                time.sleep(1.2)
                self.mac.cmux("terminal", a["term"], "write", "--text", "\r", check=False)
            else:
                self.mac.cmux("agents", "chat", "send", a["chat"], "--", text, check=False, timeout=60)
        except Exception as e:
            self.rec.log(f"load: nudge {a['name']} failed: {str(e)[:120]}")

    def feed_loop(self):
        levels = ["info", "info", "info", "warning", "error"]
        while not self.stop.wait(self.feed_interval):
            if not self.agents:
                continue
            a = random.choice(self.agents)
            i = self.feed_count + 1
            try:
                self.mac.cmux("notification", "create", "--title", f"{a['name']}: step {i}",
                              "--body", random.choice([
                                  "Finished a turn: wrote 3 files, ran the tests (12 passed).",
                                  "Needs your review: the migration touches 14 tables.",
                                  "Build failed: error[E0382] borrow of moved value `items` at src/main.rs:88",
                                  "Waiting on you: allow running `npm install`?",
                                  "Done. " + "A long summary line that wraps on the phone. " * 3,
                              ]), "--level", random.choice(levels), "--workspace", a["ws"],
                              check=False, timeout=20)
                self.feed_count = i
            except Exception as e:
                self.errors.append({"feed": str(e)[:200]})


class Stress(Journey):
    """The phone half: every user path, judged, under the load above."""

    def __init__(self, sim, mac, out, app_path, log, rec, load):
        super().__init__(sim, mac, out, app_path, log)
        self.rec, self.load = rec, load
        self.cycle = 0

    # ---------------------------------------------------------------- helpers
    def scroll_collect(self, ident_prefix, max_flings=40):
        seen, stale = [], 0
        for _ in range(max_flings):
            labels = [(e.label or "").split(",")[0] for e in self.sim.find(ident=ident_prefix + "*", kind="Button")]
            new = [l for l in labels if l and l not in seen]
            seen += new
            if not new:
                stale += 1
                if stale >= 2:
                    break
            else:
                stale = 0
            self.sim.swipe(201, 700, 201, 250, 0.25)
            time.sleep(0.7)
        return seen

    def timed_wait(self, budget, **q):
        t = time.time()
        e = self.sim.wait(timeout=budget, **q)
        return e, time.time() - t

    def screen_labels(self, n=8):
        return [e.label for e in self.sim.tree() if e.label and 0 <= e.frame[0] < 402 and 90 < e.frame[1] < 800][:n]

    def open_ws_row(self, name):
        self.back_to_list()
        for _ in range(30):
            row = self.sim.find(prefix=name, kind="Button")
            if row:
                return self.sim.tap_el(row[0])
            self.sim.swipe(201, 700, 201, 300, 0.3)
            time.sleep(0.6)
        raise Fail(f"workspace row {name} not found after scrolling the list")

    # ------------------------------------------------------------------ paths
    def p_home(self):
        self.back_to_list()
        t = time.time()
        self.tab("Home")
        time.sleep(1.0)
        labels = self.screen_labels()
        check(labels, "Home shows nothing")
        return {"notes": f"Home in {time.time()-t:.2f} s: {labels[:4]}", "metric_s": round(time.time() - t, 2)}

    def p_feed_scroll(self):
        self.back_to_list()
        t = time.time()
        self.tab("Feed")
        time.sleep(1.0)
        first = self.screen_labels(12)
        check(first, "Feed shows nothing")
        flings = []
        for _ in range(4):
            t1 = time.time()
            self.sim.swipe(201, 720, 201, 200, 0.2)
            flings.append(round(time.time() - t1, 2))
            time.sleep(0.5)
        for _ in range(4):
            self.sim.swipe(201, 200, 201, 720, 0.2)
            time.sleep(0.4)
        top = self.screen_labels(6)
        return {"notes": f"Feed opened in {time.time()-t:.2f} s; first rows {first[:3]}; back at top {top[:2]}",
                "metric_s": round(time.time() - t, 2)}

    def p_feed_open_item(self):
        self.back_to_list()
        self.tab("Feed")
        time.sleep(1.0)
        cells = [e for e in self.sim.tree() if e.kind in ("Button", "Cell") and e.label and 140 < e.frame[1] < 700
                 and 0 <= e.frame[0] < 60 and e.frame[2] > 250]
        if not cells:
            cells = [e for e in self.sim.find(kind="Button") if 140 < e.frame[1] < 700 and e.frame[2] > 250]
        check(cells, f"no Feed cell to open; screen {self.screen_labels()}")
        before = self.screen_labels(6)
        t = self.sim.tap_el(cells[0])
        time.sleep(2.0)
        after = self.screen_labels(6)
        check(after != before, f"tapping the Feed item '{cells[0].label[:60]}' changed nothing")
        return {"notes": f"opened '{cells[0].label[:60]}' -> {after[:3]}", "metric_s": round(time.time() - t, 2)}

    def p_ws_list(self):
        self.back_to_list()
        t = time.time()
        self.tab("Workspaces")
        rows = self.scroll_collect("workspace.row.")
        mac = [w["name"] for w in (self.mac.cmux("workspace", "list", json_out=True) or []) if w.get("kind") != "home"]
        missing = [n for n in mac if n not in rows]
        extra = [n for n in rows if n not in mac]
        for _ in range(12):  # back to the top
            self.sim.swipe(201, 250, 201, 750, 0.15)
        check(len(missing) <= 1 and not extra, f"phone list vs Mac: {len(rows)} rows vs {len(mac)}; missing {missing[:8]}, extra {extra[:8]}")
        return {"notes": f"{len(rows)} rows, Mac has {len(mac)} (scrolled the whole list in {time.time()-t:.1f} s)",
                "metric_s": round(time.time() - t, 2)}

    def _agent(self, kind):
        cands = [a for a in self.load.agents if a["kind"] == kind]
        check(cands, f"no {kind} agent started yet")
        return random.choice(cands)

    def p_open_terminal_agent(self):
        a = self._agent("terminal")
        t = self.open_ws_row(a["name"])
        e, dt = self.timed_wait(20, ident="terminal.composer.field")
        check(e, f"{a['name']}: the terminal never came up (no composer in 20 s); screen {self.screen_labels()}")
        time.sleep(2.0)
        words = [o[4] for o in self.sim.ocr() if 80 < o[1] < 700]
        check(len(words) >= 3, f"{a['name']}: the terminal is blank on the phone (OCR {words[:5]})")
        return {"notes": f"{a['name']} terminal in {time.time()-t:.2f} s; {len(words)} text lines visible, e.g. {words[:3]}",
                "metric_s": round(time.time() - t, 2)}

    def p_terminal_follow_up(self):
        a = self._agent("terminal")
        self.open_ws_row(a["name"])
        check(self.sim.wait(ident="terminal.composer.field", timeout=20), f"{a['name']}: no composer")
        text = random.choice(FOLLOW_UPS)
        self.sim.tap_q(ident="terminal.composer.field")
        time.sleep(0.6)
        self.sim.dismiss_keyboard_intro()
        self.sim.softtype(text)
        t = self.sim.tap_q(ident="terminal.composer.send")
        got = None
        while time.time() - t < 15:
            scr = self.mac.cmux("terminal", a["term"], "screen", "read", json_out=True, timeout=20).get("text", "")
            if text in scr:
                got = time.time() - t
                break
            time.sleep(0.5)
        self.hide_keyboard()
        check(got is not None, f"{a['name']}: '{text}' sent from the phone never reached the Mac terminal in 15 s")
        return {"notes": f"'{text}' reached Codex's terminal on the Mac in {got:.2f} s", "metric_s": round(got, 2)}

    def p_open_gui_agent(self):
        a = self._agent("gui")
        t = self.open_ws_row(a["name"])
        i, e = self.sim.wait_any([dict(ident="conversation.transcript"), dict(ident="terminal.composer.field"),
                                  dict(contains="hasn't started")], timeout=25)
        check(i is not None, f"{a['name']}: the agent chat never came up in 25 s; screen {self.screen_labels()}")
        check(i == 0, f"{a['name']}: opened on {['chat', 'a terminal', 'the not-started notice'][i]}, expected the Codex chat")
        time.sleep(1.5)
        bubbles = [x.label for x in self.sim.find(ident="conversation.transcript")][:3]
        return {"notes": f"{a['name']} chat in {time.time()-t:.2f} s; {bubbles}", "metric_s": round(time.time() - t, 2)}

    def p_gui_follow_up(self):
        a = self._agent("gui")
        self.open_ws_row(a["name"])
        check(self.sim.wait(ident="conversation.transcript", timeout=25), f"{a['name']}: chat not shown")
        field = self.sim.wait(ident="conversation.composer.text", timeout=5) or self.sim.wait(ident="chat.composer.field", timeout=2) or \
            self.sim.wait(contains="Follow up", timeout=5) or self.sim.wait(kind="TextView", timeout=3)
        check(field, f"{a['name']}: no composer in the agent chat; screen {self.screen_labels()}")
        self.sim.tap_el(field)
        time.sleep(0.8)
        self.sim.dismiss_keyboard_intro()
        text = random.choice(FOLLOW_UPS)
        self.sim.softtype(text)
        send = self.sim.find(ident="conversation.composer.send") or self.sim.find(label="Send", kind="Button")
        check(send, f"{a['name']}: no Send button")
        t = self.sim.tap_el(send[0])
        shown = None
        while time.time() - t < 10:
            if any(text in (e.label or "") for e in self.sim.find(ident="conversation.transcript")) or self.sim.find(contains=text):
                shown = time.time() - t
                break
            time.sleep(0.4)
        self.hide_keyboard()
        check(shown is not None, f"{a['name']}: the sent follow-up '{text}' never showed in the chat in 10 s")
        return {"notes": f"follow-up '{text}' shown in {shown:.2f} s", "metric_s": round(shown, 2)}

    def p_tab_grid(self):
        a = random.choice(self.load.agents) if self.load.agents else None
        check(a, "no agents yet")
        self.open_ws_row(a["name"])
        time.sleep(1.5)
        self.hide_keyboard()
        t = self.sim.tap_q(label="Tabs", kind="Button")
        time.sleep(1.2)
        cards = [e.label for e in self.sim.find(kind="Button") if e.label and "," in e.label][:6]
        check(cards, f"{a['name']}: tab grid shows no cards; screen {self.screen_labels()}")
        return {"notes": f"grid in {time.time()-t:.2f} s: {cards[:4]}", "metric_s": round(time.time() - t, 2)}

    def p_settings(self):
        self.back_to_list()
        t = time.time()
        self.tab("Settings")
        time.sleep(1.2)
        rows = [e.label for e in self.sim.find(kind="Button") if e.label and 100 < e.frame[1] < 780][:14]
        check(rows, f"Settings shows no rows; screen {self.screen_labels()}")
        visited, slow = [], []
        for r in random.sample(rows, min(6, len(rows))):
            el = self.sim.find(label=r, kind="Button")
            if not el:
                continue
            t1 = self.sim.tap_el(el[0])
            time.sleep(1.2)
            visited.append(r)
            back = self.sim.find(ident="BackButton") or self.sim.find(label="Back", kind="Button") or \
                self.sim.find(label="Settings", kind="Button")
            if back:
                self.sim.tap_el(back[0])
                time.sleep(0.8)
            elif self.sim.find(label="Sheet Grabber"):
                self.back_to_list()
                self.tab("Settings")
        return {"notes": f"Settings in {time.time()-t:.2f} s; rows {rows[:8]}; visited {visited}", "metric_s": round(time.time() - t, 2)}

    def p_create_ws(self):
        self.back_to_list()
        self.tab("Workspaces")
        r = self.s_create_workspace()
        return r

    def p_chief(self):
        try:
            return self.s_chief()
        except Blocked as b:  # s_chief reports send/receive as not run; loading is the check here
            return {"notes": str(b)}

    def p_background(self):
        return self.s_background()

    def p_relaunch(self):
        t = self.sim.launch(BUNDLE)
        e, dt = self.timed_wait(30, label="Workspaces", kind="RadioButton")
        check(e, "relaunch never reached the tab bar in 30 s")
        return {"notes": f"cold relaunch to the tab bar in {time.time()-t:.2f} s", "metric_s": round(time.time() - t, 2)}

    PATHS = [
        ("home", "Home tab", p_home),
        ("feed_scroll", "Feed: open and fling through it", p_feed_scroll),
        ("feed_open_item", "Feed: open an item", p_feed_open_item),
        ("ws_list", "Workspaces: whole list matches the Mac", p_ws_list),
        ("open_terminal_agent", "Open a Codex terminal agent", p_open_terminal_agent),
        ("terminal_follow_up", "Send a follow-up to a terminal agent from the composer", p_terminal_follow_up),
        ("open_gui_agent", "Open a Codex agent chat", p_open_gui_agent),
        ("gui_follow_up", "Send a follow-up in an agent chat", p_gui_follow_up),
        ("tab_grid", "Tab grid of a busy workspace", p_tab_grid),
        ("settings", "Settings pages", p_settings),
        ("create_ws", "New workspace from the phone", p_create_ws),
        ("chief", "Chief loads", p_chief),
        ("background", "Background and foreground", p_background),
        ("relaunch", "Cold relaunch", p_relaunch),
    ]

    def walk(self, only=None):
        self.cycle += 1
        video = os.path.join(self.out, "video", f"cycle-{self.cycle:02d}.mp4")
        os.makedirs(os.path.dirname(video), exist_ok=True)
        try:
            self.sim.record_start(video)
        except RuntimeError as e:
            self.log(f"recording did not start: {e}")
            video = None
        load = self.load.counts()
        try:
            for sid, title, fn in self.PATHS:
                if only and sid not in only:
                    continue
                before = len(self.results)
                self.step(sid, title, "stress", lambda fn=fn: fn(self))
                rec = self.results[before] if len(self.results) > before else {}
                self.rec.jsonl("cycles.jsonl", dict(rec, cycle=self.cycle, load=load,
                                                    video=os.path.relpath(video, self.out) if video else None))
                if rec.get("status") == "fail":
                    try:
                        self.back_to_list()
                    except Exception:
                        self.sim.launch(BUNDLE)
                        time.sleep(4)
        finally:
            self.sim.record_stop()


def sampler(rec, sim, mac, load, stop):
    def ps(pid):
        if not pid:
            return None
        out = subprocess.run(["ps", "-o", "%cpu=,rss=", "-p", str(pid)], capture_output=True, text=True).stdout.split()
        return {"cpu": float(out[0]), "rss_mb": round(int(out[1]) / 1024, 1)} if len(out) == 2 else None

    def phone_pid():
        r = subprocess.run(["pgrep", "-f", f"{sim.udid}/data/Containers/Bundle/Application/.*/CmuxMobileApp.app/CmuxMobileApp"],
                           capture_output=True, text=True)
        return int(r.stdout.split()[0]) if r.stdout.split() else None

    while not stop.wait(5):
        rec.jsonl("metrics.jsonl", {"phone": ps(phone_pid()), "mac": ps((mac.main_pids() or [None])[0]),
                                    "hostd": ps((mac.hostd_pids() or [None])[0]), "load1": round(os.getloadavg()[0], 2),
                                    **load.counts()})


def ensure_sim(name, log):
    lst = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "-j"], capture_output=True, text=True).stdout)
    for devs in lst["devices"].values():
        for d in devs:
            if d["name"] == name:
                udid = d["udid"]
                break
        else:
            continue
        break
    else:
        udid = subprocess.run(["xcrun", "simctl", "create", name, DEVICE, RUNTIME], capture_output=True, text=True).stdout.strip()
        log(f"created simulator {name} {udid}")
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], capture_output=True, timeout=600)
    return udid


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mac-app", required=True)
    ap.add_argument("--ios-app", required=True)
    ap.add_argument("--codex", default=os.path.expanduser("~/a146/npm/bin/codex"))
    ap.add_argument("--node-bin", default=os.path.expanduser("~/.local/share/cmux-node/node-v24.20.0-darwin-arm64/bin"))
    ap.add_argument("--sim-name", default="cmux-a146-stress")
    ap.add_argument("--cycles", type=int, default=6)
    ap.add_argument("--start-agents", type=int, default=4)
    ap.add_argument("--add-per-cycle", type=int, default=4)
    ap.add_argument("--max-agents", type=int, default=40)
    ap.add_argument("--feed-interval", type=float, default=4.0)
    ap.add_argument("--paths", help="comma list of path ids (default: all)")
    ap.add_argument("--skip-setup", action="store_true", help="the phone is already signed in and paired")
    ap.add_argument("--out", default=os.path.expanduser(f"~/a146/runs/{datetime.datetime.now():%Y%m%d-%H%M%S}"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()

    rec = Recorder(a.out)
    mac_app = os.path.abspath(a.mac_app)
    refuse_other_rigs(pb(os.path.join(mac_app, "Contents/Info.plist"), "Print :CFBundleIdentifier"))
    rig = os.path.expanduser(f"~/cmux-next-ios-e2e/{os.path.basename(mac_app)[len('cmux DEV '):-4]}")
    mac = Mac(rig, mac_app, cleanup=not a.keep, log=rec.log).prepare()
    mac.seed_pairing(names=[a.sim_name])
    mac.launch_env = {"PATH": f"{os.path.dirname(a.codex)}:{a.node_bin}:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"}
    udid = ensure_sim(a.sim_name, rec.log)
    sim = Sim(udid, os.path.join(a.out, "shots"))
    rec.jsonl("meta.jsonl", {"mac_app": os.path.basename(mac_app), "mac_bundle": mac.bundle_id, "mac_tag": mac.tag,
                             "ios_app": a.ios_app, "sim": {"name": a.sim_name, "udid": udid}, "args": vars(a)})
    load = Load(mac, rec, a.codex, a.node_bin, os.path.join(rig, "proj"), a.feed_interval)
    stop = threading.Event()
    st = Stress(sim, mac, a.out, a.ios_app, rec.log, rec, load)
    try:
        mac.launch()
        rec.log(f"Mac app up (pid {mac.pid}); cmux-mobile-host {'running' if mac.wait_hostd(120) else 'NOT running'}")
        st.seed_mac()
        if not a.skip_setup:
            for sid, title, fn in (("fresh_install", "Fresh install", st.s_fresh_install), ("sign_in", "Sign in", st.s_sign_in),
                                   ("choose_space", "Choose space", st.s_choose_space), ("mac_discovered", "Mac discovered", st.s_mac_discovered)):
                ok = st.step(sid, title, "setup", fn)
                rec.jsonl("cycles.jsonl", dict(st.results[-1], cycle=0, load=load.counts()))
                if not ok and sid != "mac_discovered":
                    rec.log(f"setup step {sid} failed; stopping")
                    return 2
        threading.Thread(target=sampler, args=(rec, sim, mac, load, stop), daemon=True).start()
        threading.Thread(target=load.feed_loop, daemon=True).start()
        for _ in range(a.start_agents):
            load.add_agent()
        only = set(a.paths.split(",")) if a.paths else None
        for c in range(1, a.cycles + 1):
            rec.log(f"=== cycle {c}: load {load.counts()}")
            st.walk(only)
            summary = {s: sum(1 for r in st.results[-len(st.PATHS):] if r.get("status") == s) for s in ("pass", "fail", "blocked")}
            rec.log(f"=== cycle {c} done: {summary}; hangs so far {len(st.hangs)}")
            for _ in range(3):
                load.nudge()
            for _ in range(a.add_per_cycle):
                if len(load.agents) < a.max_agents:
                    load.add_agent()
        return 0
    except Exception:
        rec.log("stress loop error: " + traceback.format_exc(limit=4))
        return 1
    finally:
        stop.set()
        load.stop.set()
        json.dump({"hangs": st.hangs, "load_errors": load.errors, "final_load": load.counts()},
                  open(os.path.join(a.out, "final.json"), "w"), indent=2, default=str)
        if not a.keep:
            mac.teardown()
            subprocess.run(["xcrun", "simctl", "shutdown", udid], capture_output=True)
            subprocess.run(["xcrun", "simctl", "delete", udid], capture_output=True)
        rec.log("stress loop done")


if __name__ == "__main__":
    sys.exit(main())
