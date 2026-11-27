"""Terminal agents in the Feed, live over the real link (verify/terminal-feed-parity.md).

Runs ON a cmux mini, beside a hidden rig Mac (multimac/rig.py, in RIG) where a real Claude
Code runs in a cmux terminal tab (TERM). One headless simulator runs the iOS app (Demo,
DEBUG dev sign-in). Each flow is started on the Mac by typing into that terminal through
the rig's own CLI (never this Mac's input). The Feed card is read off the phone. A reply
typed in the Feed must reach the agent: the Mac terminal shows it, and a new turn ends.
Then the same kinds of event from a GUI chat (acpmux's fake agent) for the side-by-side.

    python3 terminal_feed_live.py --app PATH --udid UDID --rig DIR --term TERM_ID [--out DIR] [--keep-install]

Writes DIR/results.json, DIR/run.log, DIR/shots/ and DIR/terminal-feed.mp4.
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "e2e"))
from journey import Fail, Journey, check  # noqa: E402
from sim import Sim  # noqa: E402


class Rig:
    def __init__(self, base, term):
        self.base, self.term = base, term

    def run(self, *args, timeout=90):
        r = subprocess.run(["python3", "rig.py", *args], cwd=self.base, capture_output=True, text=True, timeout=timeout)
        return r.stdout

    def write(self, text):
        self.run("cli", "terminal", self.term, "write", "--text", text)

    def enter(self):
        self.write("\r")

    def screen(self):
        out = self.run("cli", "--json", "terminal", self.term, "screen", "read")
        try:
            return json.loads(out).get("text", "")
        except ValueError:
            return ""

    def wait_screen(self, needle, timeout=120.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            text = self.screen()
            if needle in text:
                return text
            time.sleep(1.0)
        return None

    def prompt(self, text):
        self.write(text)
        time.sleep(0.8)
        self.enter()

    def ask(self, text):
        self.run("ask", text)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--udid", required=True)
    ap.add_argument("--rig", required=True)
    ap.add_argument("--term", required=True)
    ap.add_argument("--out", default=os.path.join(HERE, "evidence", time.strftime("%Y%m%d-%H%M%S") + "-terminal-feed"))
    ap.add_argument("--keep-install", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    logf = open(os.path.join(a.out, "run.log"), "a")

    def log(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        logf.write(line + "\n")
        logf.flush()

    rig = Rig(a.rig, a.term)
    sim = Sim(a.udid, shots_dir=os.path.join(a.out, "shots"))
    j = Journey(sim, None, a.out, a.app, log)
    results = {"checks": {}}

    def texts():
        return [t for t in sim.texts() if t]

    def wait_text(needle, timeout=90.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            hits = [t for t in texts() if needle in t]
            if hits:
                return hits
            time.sleep(1.0)
        return []

    def feed_top():
        """Scrolls the Feed to its top (the newest event)."""
        for _ in range(3):
            sim.drag(201, 250, 201, 750, 0.3, 20, 0.1)
            time.sleep(0.4)

    if not a.keep_install:
        j.s_fresh_install()
        j.s_sign_in()
        j.s_choose_space()
    log("signed in")
    # The Mac's tree arrives on Workspaces; then the Feed.
    j.tab("Workspaces")
    check(wait_text("tf-claude", 90), "the rig Mac's workspace never showed on the phone")
    j.tab("Feed")
    time.sleep(2.0)
    video = os.path.join(a.out, "terminal-feed.mp4")
    sim.record_start(video)
    try:
        def approve_until(marker, timeout=240.0, answer="\r"):
            """Answers each prompt Claude shows on the Mac (its first option) until the Feed shows `marker`."""
            deadline = time.time() + timeout
            approvals = 0
            while time.time() < deadline:
                if any(marker in t for t in texts()):
                    return approvals
                screen = rig.screen()
                if "Do you want" in screen or "Enter to select" in screen or "Submit answers" in screen:
                    rig.write(answer)
                    approvals += 1
                    time.sleep(2.0)
                time.sleep(1.0)
            return None

        def top_reply():
            buttons = sorted(sim.find(label="Reply", kind="Button"), key=lambda e: e.frame[1])
            return buttons[0] if buttons else None

        # 1. A prompt that edits a file: approvals (answered on the Mac), then the finished turn.
        rig.prompt("Fix the bug in calc.py so mul returns the product. Do not run anything. "
                   "Then reply with a markdown heading that is the word mango in capital letters, and one bullet saying what you changed.")
        hit = wait_text("Needs approval", 120)
        sim.shot("01-edit-needs-approval")
        results["checks"]["edit_approval_card"] = bool(hit)
        n = approve_until("MANGO")
        time.sleep(2.0)
        feed_top()
        sim.shot("02-edit-finished")
        t = texts()
        results["checks"]["edit_finished_has_prompt_quote"] = any("so mul returns the product" in x for x in t)
        results["checks"]["edit_finished_has_answer"] = n is not None
        log(f"edit finished after {n} approvals: {[x for x in t if 'MANGO' in x or 'mul' in x][:4]}")

        # 2. Reply from the Feed: typed into Claude's prompt and submitted; a new turn ends.
        reply = top_reply()
        check(reply, "no Reply on the terminal agent's finished card")
        sim.tap_el(reply)
        time.sleep(1.2)
        sim.dismiss_keyboard_intro()
        sim.softtype("Now reply with just the word pineapple in capital letters")
        send = sim.wait(label="Send reply", timeout=10)
        check(send, "no Send reply button")
        t0 = time.time()
        sim.tap_el(send)
        sim.shot("03-reply-sending")
        reached = rig.wait_screen("pineapple in capital", 60)
        results["checks"]["reply_reached_terminal"] = bool(reached)
        results["checks"]["reply_seconds"] = round(time.time() - t0, 2)
        sent = wait_text("Sent to the terminal", 30)
        results["checks"]["reply_card_says_sent"] = bool(sent)
        failure = [x for x in texts() if "reply was not sent" in x or "refused" in x]
        log(f"reply reached the terminal: {bool(reached)} in {results['checks']['reply_seconds']} s; card: {sent[:1]} {failure[:1]}")
        sim.shot("04-reply-sent")
        hit = approve_until("PINEAPPLE", 120)
        time.sleep(2.0)
        feed_top()
        sim.shot("05-reply-answered")
        results["checks"]["reply_answer_card"] = hit is not None

        # 3. A command that needs permission: approval card, answered in the terminal.
        rig.prompt("Run the shell command `ls -la` in this folder, then reply with the word kiwi in capital letters and the number of files.")
        hit = wait_text("Needs approval", 120)
        feed_top()
        sim.shot("06-command-needs-approval")
        results["checks"]["command_approval_card"] = bool(hit)
        results["checks"]["command_finished"] = approve_until("KIWI") is not None
        time.sleep(2.0)
        feed_top()
        sim.shot("07-command-finished")

        # 4. AskUserQuestion: a question card (answered in the terminal here; the rich-push lane owns inline).
        rig.prompt("Use the AskUserQuestion tool to ask me which color I prefer, with the options Red and Blue. "
                   "Then reply with the word lemon in capital letters and my choice.")
        hit = wait_text("question", 120)
        feed_top()
        sim.shot("08-question")
        results["checks"]["question_card"] = bool(hit)
        results["checks"]["question_finished"] = approve_until("LEMON") is not None
        time.sleep(2.0)
        feed_top()
        sim.shot("09-question-answered")

        # 5. An error: a failing tool's text on the card.
        rig.prompt("Run the shell command `swiftlint-not-installed --version` exactly once. "
                   "If it fails, reply with the word plum in capital letters and nothing else.")
        hit = None
        deadline = time.time() + 180
        while time.time() < deadline and not hit:
            if "Do you want" in rig.screen():
                rig.enter()
                time.sleep(2.0)
            hit = [x for x in texts() if "not found" in x]
            time.sleep(1.0)
        feed_top()
        sim.shot("10-error")
        results["checks"]["error_text_card"] = bool(hit)
        log(f"error card: {hit[:1] if hit else None}")
        approve_until("PLUM", 120)
        time.sleep(2.0)
        feed_top()
        sim.shot("11-error-turn-finished")

        # 6. The same kinds from a GUI chat (acpmux fake agent): a permission card, then its finished turn.
        rig.ask("ask: git push origin main")
        deny = sim.wait(label="Deny", kind="Button", timeout=90)
        feed_top()
        sim.shot("12-gui-permission")
        results["checks"]["gui_permission_card"] = bool(deny)
        if deny:
            sim.tap_el(deny)
        time.sleep(6.0)
        feed_top()
        sim.shot("13-gui-finished")
    finally:
        sim.record_stop()
        with open(os.path.join(a.out, "results.json"), "w") as f:
            json.dump(results, f, indent=2)
        log(json.dumps(results["checks"]))


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"FAIL: {e}", file=sys.stderr)
        sys.exit(1)
