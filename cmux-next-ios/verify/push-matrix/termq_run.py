"""Runs ON the rich-push rig's mini: the terminal agent question rows
(verify/push-matrix-terminal-questions.md), on the verification lane's rig
(pushrig.py, pushphone.py: the hidden rig Mac, the "richpush-phone" simulator).

A real Claude Code session runs in a rig terminal tab and asks AskUserQuestion;
the phone answers from the Feed card and from the notification; the rig
terminal shows Claude received the choice and went on. It builds nothing, boots
no simulator and starts no rig Mac: run it only in a slot the verification lane
gave you, after `pushrig.py launch` and `pushphone.py setup`.

    python3 termq_run.py all            # every row below, with one video
    python3 termq_run.py open           # a rig workspace + terminal running claude
    python3 termq_run.py feed-single    # 3-option question, answered from the Feed card
    python3 termq_run.py push-multi     # single + multiSelect, answered from the notification
    python3 termq_run.py tap-cold       # app not running: tapping the push opens the terminal tab
    python3 termq_run.py close          # closes the rig workspace (claude exits with it)

Evidence: ~/richpush-verify/evidence/termq-*.png|mp4 and termq-results.json.
"""
import glob
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.expanduser("~/richpush-verify")
OUT = os.environ.get("PUSHRIG_OUT", os.path.join(ROOT, "evidence"))
STATE = os.path.join(ROOT, "termq.json")
RESULTS = os.path.join(OUT, "termq-results.json")
MAC_NAME = os.environ.get("PUSHRIG_MAC_NAME", "Rig Mac")
WS_NAME = "termq-rig"
# Claude Code through the rig app's own cmux-tui wrapper, which gives it this build's
# agent hooks. Not the per-user shim on PATH: on a shared mini it can point at another
# build's cmux-tui (or one that is gone, and then Claude Code runs with no hooks at all).
CLAUDE = "'" + (glob.glob(os.path.join(ROOT, "rig/mac/*.app/Contents/Resources/bin/cmux-tui")) or ["cmux-tui"])[0] \
    + "' agent claude-wrapper"

SINGLE = ("Call the AskUserQuestion tool exactly once with one question: header Branch, question "
          "Which branch should I use?, single choice, options main, dev, release. Then reply only "
          "with GOT followed by the answer.")
MULTI = ("Call the AskUserQuestion tool exactly once with two questions: first header Branch, question "
         "Which branch next?, single choice, options main, dev, release; second header Checks, question "
         "Which checks should run?, multiSelect true, options lint, tests, docs. Then reply only with GOT "
         "followed by the answers.")


def py(script, *args, timeout=240, check=True):
    r = subprocess.run([sys.executable, os.path.join(HERE, script), *args], capture_output=True, text=True,
                       timeout=timeout)
    if check and r.returncode != 0:
        raise SystemExit(f"{script} {' '.join(args)}: {(r.stderr or r.stdout).strip()[-400:]}")
    return r.stdout


def rig(*args, **kw):
    return py("pushrig.py", *args, **kw)


def phone(*args, **kw):
    return py("pushphone.py", *args, **kw)


def cli_json(*args):
    out = rig("cli", "--json", *args)
    return json.loads(out) if out.strip() else {}


def state():
    return json.load(open(STATE)) if os.path.exists(STATE) else {}


def save(**kw):
    s = state() | kw
    json.dump(s, open(STATE, "w"), indent=1)
    return s


def screen(term):
    return (cli_json("terminal", term, "screen", "read") or {}).get("text", "")


def wait_screen(term, needle, timeout=120):
    """Waits (bounded) for the rig terminal to show `needle`; returns the screen."""
    deadline = time.time() + timeout
    text = ""
    while time.time() < deadline:
        text = screen(term)
        if needle in text:
            return text
        time.sleep(1)
    raise SystemExit(f"rig terminal never showed {needle!r}; tail: {text[-300:]!r}")


def write(term, text):
    """Types `text`; a trailing Return goes as its own write, since Claude Code reads a
    Return that arrives with text as part of a paste (the probe in tmux sent them apart)."""
    body, enter = (text[:-1], True) if text.endswith("\r") and len(text) > 1 else (text, False)
    rig("cli", "terminal", term, "write", "--text", body)
    if enter:
        time.sleep(0.6)
        rig("cli", "terminal", term, "write", "--text", "\r")


def record(row, ok, note, evidence):
    results = json.load(open(RESULTS)) if os.path.exists(RESULTS) else []
    results = [r for r in results if r["row"] != row] + [{"row": row, "pass": ok, "note": note, "evidence": evidence}]
    json.dump(results, open(RESULTS, "w"), indent=1)
    print(json.dumps(results[-1]))


def open_terminal():
    os.makedirs(OUT, exist_ok=True)
    r = cli_json("workspace", "create", "--name", WS_NAME)["value"]
    s = save(ws=r["workspace_id"], term=r["terminal_id"], tab=r["tab_id"])
    work = os.path.join(ROOT, "rig", "termq-work")
    os.makedirs(work, exist_ok=True)
    # A folder Claude Code already trusts would skip the prompt; answer it if it shows.
    write(s["term"], f"cd {work} && {CLAUDE} --model haiku --allowedTools AskUserQuestion\r")
    deadline = time.time() + 90
    while time.time() < deadline:
        text = screen(s["term"])
        if "Yes, I trust this folder" in text:
            write(s["term"], "\x1b[B\r")
        elif "auto mode" in text or "\u276f" in text.split("\n")[-4:-3][0:1] or "Try \"" in text:
            break
        time.sleep(1)
    else:
        raise SystemExit(f"Claude Code did not start: {screen(s['term'])[-300:]!r}")
    print(json.dumps(s))


def ask(prompt, first_question):
    s = state()
    write(s["term"], prompt + "\r")
    # The prompt itself shows the question's words: wait for the question screen's own footer.
    text = wait_screen(s["term"], "Enter to select", timeout=180)
    if first_question not in text.split("Enter to select")[0].split("❯")[0] + text:
        raise SystemExit(f"another question is on screen: {text[-300:]!r}")
    return s


def latest_question_payload(after):
    """The newest question push the real host posted since `after` lines, as the Worker's APNs body."""
    captured = rig("captured").splitlines()[after:]
    lines = [l for l in captured if json.loads(l).get("event", {}).get("kind") == "question"]
    if not lines:
        raise SystemExit("the Mac host posted no question push")
    capture = os.path.join(OUT, "termq-capture.jsonl")
    open(capture, "w").write(lines[-1] + "\n")
    outdir = os.path.join(OUT, "termq-apns")
    subprocess.run(["rm", "-rf", outdir])
    subprocess.run(["node", os.path.join(HERE, "apns-from-capture.ts"), capture, outdir, MAC_NAME], check=True,
                   capture_output=True, timeout=60)
    return sorted(glob.glob(os.path.join(outdir, "*.json")))[-1]


def feed_single():
    phone("launch")
    before = len(rig("captured").splitlines())
    s = ask(SINGLE, "Which branch should I use?")
    payload = latest_question_payload(before)
    phone("tap", "Feed", "--kind", "RadioButton", check=False)
    time.sleep(2)
    phone("shot", "termq-feed-single-card")
    phone("tap", "dev", "--kind", "Button")
    text = wait_screen(s["term"], "GOT", timeout=90)
    phone("shot", "termq-feed-single-answered")
    ok = "dev" in text.split("GOT")[-1]
    record("feed-single", ok, f"Claude: GOT{text.split('GOT')[-1][:60]!r}; push body {os.path.basename(payload)}",
           ["termq-feed-single-card.png", "termq-feed-single-answered.png"])


def push_multi():
    before = len(rig("captured").splitlines())
    s = ask(MULTI, "Which branch next?")
    payload = latest_question_payload(before)
    phone("background")
    phone("push", payload)
    time.sleep(3)
    phone("nc")
    phone("shot", "termq-push-multi-banner")
    phone("expand", "Which branch next?")
    phone("shot", "termq-push-multi-longlook")
    phone("tap", "release")
    phone("tap", "lint")
    phone("tap", "docs")
    phone("tap", "Submit")
    time.sleep(2)
    phone("faceid", "match", check=False)
    text = wait_screen(s["term"], "GOT", timeout=90)
    phone("shot", "termq-push-multi-answered")
    got = text.split("GOT")[-1]
    ok = all(word in got for word in ("release", "lint", "docs")) and "tests" not in got
    record("push-multi", ok, f"Claude: GOT{got[:80]!r}",
           ["termq-push-multi-banner.png", "termq-push-multi-longlook.png", "termq-push-multi-answered.png"])


def tap_cold():
    before = len(rig("captured").splitlines())
    s = ask(SINGLE, "Which branch should I use?")
    payload = latest_question_payload(before)
    phone("terminate")
    phone("push", payload)
    time.sleep(3)
    phone("nc")
    phone("tap", "Which branch should I use?")
    time.sleep(6)
    phone("shot", "termq-tap-cold-opened")
    texts = phone("texts")
    ok = WS_NAME in texts or "termq-work" in texts
    record("tap-cold", ok, "opened on the rig terminal tab" if ok else f"opened elsewhere: {texts[:200]!r}",
           ["termq-tap-cold-opened.png"])
    # Leave Claude ready for the next row.
    write(s["term"], "\x1b")


def close():
    s = state()
    if s.get("ws"):
        rig("cli", "workspace", s["ws"], "close", check=False)
    if os.path.exists(STATE):
        os.remove(STATE)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "all"
    rows = {"open": open_terminal, "feed-single": feed_single, "push-multi": push_multi,
            "tap-cold": tap_cold, "close": close}
    if cmd != "all":
        return rows[cmd]()
    phone("record", "start", "termq-all")
    try:
        open_terminal()
        for row in ("feed-single", "push-multi", "tap-cold"):
            try:
                rows[row]()
            except SystemExit as failure:
                record(row, False, str(failure), [])
    finally:
        phone("record", "stop", check=False)
        close()
    print(open(RESULTS).read())


if __name__ == "__main__":
    main()
