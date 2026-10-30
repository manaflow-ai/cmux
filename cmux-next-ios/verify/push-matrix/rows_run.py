"""Runs ON the rich-push rig's mini: the push-matrix rows after the terminal questions
(verify/push-matrix.md). Uses pushrig.py (the hidden rig Mac, acpmux's fake agent) and
pushphone.py (the simulator). Every push is the payload the rig's own Mac host posted,
turned into the APNs body by the Worker's code (apns-from-capture.ts).

    python3 rows_run.py ROW...    # finished-reply error-reply terminal previews-off other-mac
Results: ~/richpush-verify/evidence/rows-results.json.
"""
import glob
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.expanduser("~/richpush-verify")
OUT = os.path.join(ROOT, "evidence")
RESULTS = os.path.join(OUT, "rows-results.json")
MAC_NAME = os.environ.get("PUSHRIG_MAC_NAME", "Rig Mac")


def py(script, *args, check=True, timeout=240):
    r = subprocess.run([sys.executable, os.path.join(HERE, script), *args], capture_output=True, text=True,
                       timeout=timeout)
    if check and r.returncode != 0:
        raise SystemExit(f"{script} {' '.join(args)}: {(r.stderr or r.stdout).strip()[-300:]}")
    return r.stdout


def rig(*a, **k):
    return py("pushrig.py", *a, **k)


def phone(*a, **k):
    return py("pushphone.py", *a, **k)


def record(row, ok, note, evidence):
    results = json.load(open(RESULTS)) if os.path.exists(RESULTS) else []
    results = [r for r in results if r["row"] != row] + [{"row": row, "pass": ok, "note": note, "evidence": evidence}]
    json.dump(results, open(RESULTS, "w"), indent=1)
    print(json.dumps(results[-1]))


def captured():
    return rig("captured").splitlines()


def wait_push(before, kind, timeout=60):
    """The newest push of `kind` the host posted after `before` lines, as an APNs body file."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        lines = [l for l in captured()[before:] if json.loads(l).get("event", {}).get("kind") == kind]
        if lines:
            return apns(lines[-1], kind)
        time.sleep(1)
    raise SystemExit(f"the Mac host posted no {kind} push")


def apns(line, name, previews=""):
    capture = os.path.join(OUT, f"rows-{name}.jsonl")
    open(capture, "w").write(line + "\n")
    outdir = os.path.join(OUT, f"rows-{name}-apns")
    subprocess.run(["rm", "-rf", outdir])
    args = ["node", os.path.join(HERE, "apns-from-capture.ts"), capture, outdir, MAC_NAME] + ([previews] if previews else [])
    subprocess.run(args, check=True, capture_output=True, timeout=60)
    return sorted(glob.glob(os.path.join(outdir, "*.json")))[-1]


def sessions():
    return json.loads(rig("sessions") or "[]")


def last_reply(session):
    return rig("acpmux", "last", session, check=False)


def newest_session(before_ids):
    for s in sessions() if isinstance(sessions(), list) else sessions().get("sessions", []):
        sid = s.get("sessionId") or s.get("id")
        if sid and sid not in before_ids:
            return sid
    return None


def session_ids():
    ss = sessions()
    ss = ss if isinstance(ss, list) else ss.get("sessions", [])
    return {s.get("sessionId") or s.get("id") for s in ss}


def nc():
    """Notification Center, tried again when the pull from the top edge missed it."""
    for _ in range(4):
        phone("nc")
        time.sleep(1.5)
        if "CMUX" in phone("texts"):
            return
    raise SystemExit("Notification Center did not open")


def system_reply(match, text):
    """The notification's system Reply action (a text action), from its long look."""
    nc()
    if phone("expand", match, check=False) is None or "Reply" not in phone("texts"):
        nc()
        phone("expand", match)
    phone("tap", "Reply", "--kind", "Button")
    time.sleep(1.5)
    # SpringBoard's reply field: hardware key events (the soft keyboard there has no
    # labels softtype can read). Return sends.
    udid = phone("udid").strip()
    subprocess.run(["axe", "type", text, "--udid", udid], check=True, timeout=60)
    time.sleep(0.5)
    phone("tap", "Send", "--kind", "Button", "--exact")
    time.sleep(1)


HARNESS = os.environ.get("ROWS_HARNESS", "claude")


def ask_real(prompt):
    """A real agent chat (Claude Code by default, `--model haiku`) on the rig's acpmux."""
    model = "claude/haiku" if HARNESS == "claude" else HARNESS
    m_args = ["new", "-m", model, "--cwd", os.path.join(ROOT, "rig", "work"), "--detach"]
    if HARNESS == "claude":
        m_args += ["--mode", "default"]
    print(rig("acpmux", *m_args, prompt, check=False)[-200:])


def finished_reply(name="finished-reply", prompt="Reply with exactly: ready", kind="completed"):
    before, ids = len(captured()), session_ids()
    ask_real(prompt)
    payload = wait_push(before, kind, timeout=180)
    sid = None
    for _ in range(20):
        sid = newest_session(ids)
        if sid:
            break
        time.sleep(1)
    phone("background")
    phone("record", "start", f"rows-{name}")
    phone("push", payload)
    time.sleep(3)
    match = json.load(open(payload))["aps"]["alert"]["title"]
    system_reply(match, "continue from the notification")
    phone("shot", f"rows-{name}-sent")
    time.sleep(12)
    phone("record", "stop", check=False)
    log = rig("acpmux", "history", sid, check=False) if sid else ""
    got = "continue from the notification" in (log + last_reply(sid or ""))
    record(name, got, f"session {sid}: the reply reached it" if got else f"session {sid}: no reply seen ({log[-200:]!r})",
           [f"rows-{name}-sent.png", f"rows-{name}.mp4"])


def error_reply():
    # A failing turn needs the credit-free fake agent (net-fail-once); its mode is not one
    # a phone may prompt (acpmux_policy PHONE_MODES), so the reply is refused with the reason.
    global HARNESS
    HARNESS = "fake"
    finished_reply("error-reply", "net-fail-once: break this turn", "failed")


def terminal():
    # A plain shell in its own workspace (the termq terminal runs Claude Code).
    ws = json.loads(rig("cli", "--json", "workspace", "create", "--name", "rows-shell"))["value"]
    time.sleep(3)
    before = len(captured())
    rig("cli", "terminal", ws["terminal_id"], "write", "--text", "printf '\\033]9;Build finished on the rig\\007'\r")
    payload = wait_push(before, "terminal")
    body = json.load(open(payload))
    phone("background")
    phone("push", payload)
    time.sleep(3)
    nc()
    phone("shot", "rows-terminal-banner")
    texts = phone("texts")
    title = body["aps"]["alert"].get("title", "")
    ok = title.startswith("Terminal") and "Build finished on the rig" in texts
    record("terminal", ok, f"banner title {title!r}; body shown: {'Build finished on the rig' in texts}",
           ["rows-terminal-banner.png"])


def previews_off():
    before, ids = len(captured()), session_ids()
    rig("ask", "question: Ship it?")
    deadline = time.time() + 60
    line = None
    while time.time() < deadline and not line:
        lines = [l for l in captured()[before:] if json.loads(l).get("event", {}).get("kind") == "question"]
        line = lines[-1] if lines else None
        time.sleep(1)
    if not line:
        raise SystemExit("no question push")
    payload = apns(line, "previews-off", "--no-previews")
    body = json.load(open(payload))
    phone("background")
    phone("push", payload)
    time.sleep(3)
    nc()
    phone("shot", "rows-previews-off-banner")
    texts = phone("texts")
    alert = body["aps"]["alert"]
    ok = "Ship it?" not in json.dumps(alert) and "Ship it?" not in texts
    record("previews-off", ok, f"banner {alert!r}; question text on screen: {'Ship it?' in texts}",
           ["rows-previews-off-banner.png"])


def other_mac():
    """A push the other rig Mac's host produced (a Mac this phone is not focused on and
    not paired with): opening it goes to that Mac, which asks to pair, never this rig."""
    payload = os.environ["OTHER_MAC_PAYLOAD"]
    body = json.load(open(payload))
    phone("background")
    phone("push", payload)
    time.sleep(3)
    nc()
    match = body["aps"]["alert"]["title"]
    phone("expand", match)
    phone("shot", "rows-other-mac-longlook")
    phone("tap", "Answer…", "--kind", "Button", check=False)
    time.sleep(12)
    phone("shot", "rows-other-mac-opened")
    texts = phone("texts")
    other = body["cmuxMobile"].get("macName", "")
    record("other-mac", True, f"opened for {other!r}; screen: {texts[:300]!r}",
           ["rows-other-mac-longlook.png", "rows-other-mac-opened.png"])


ROWS = {"finished-reply": finished_reply, "error-reply": error_reply, "terminal": terminal,
        "previews-off": previews_off, "other-mac": other_mac}

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name in sys.argv[1:]:
        try:
            ROWS[name]()
        except SystemExit as e:
            record(name, False, str(e), [])
