"""Runs ON the rich-push rig's mini: PR B's encrypted fallback, live (verify/push-matrix.md).

A program in a rig terminal (python3, the foreground process) posts `cmux notify --reply`
and waits for a line on stdin. The real Mac host seals the push to the phone; the Worker's
own code makes its APNs body. The phone (app killed) gets it opened by the service
extension's code (`SimulatedServiceExtension`, since `simctl push` runs no extension), the
rig Mac goes offline, the person replies from the lock-screen Reply action, the app (woken
in the background) cannot reach the Mac and seals the reply into the mailbox; the rig Mac
comes back, takes the mailbox item, checks it and types the text into that program.

    python3 fallback_run.py terminal-reply
Results: ~/richpush-verify/evidence/fallback-results.json.
"""
import glob
import json
import os
import signal
import subprocess
import sys
import time

import rows_run as r

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.expanduser("~/richpush-verify")
OUT = os.path.join(ROOT, "evidence")
RESULTS = os.path.join(OUT, "fallback-results.json")
PHONE_LINK = os.environ["PUSHRIG_PHONE_LINK"]  # the phone's link device id (rig log `phone=`)
BUNDLE = "dev.cmux.mobile"


def record(row, ok, note, evidence):
    results = json.load(open(RESULTS)) if os.path.exists(RESULTS) else []
    results = [x for x in results if x["row"] != row] + [{"row": row, "pass": ok, "note": note, "evidence": evidence}]
    json.dump(results, open(RESULTS, "w"), indent=1)
    print(json.dumps(results[-1]))


def screen(term):
    out = r.rig("cli", "terminal", term, "read", check=False)
    return out


def terminal_reply():
    cmux = glob.glob(os.path.join(ROOT, "rig/mac/*.app/Contents/Resources/bin/cmux"))[0]
    before = len(r.captured())
    ws = json.loads(r.rig("cli", "--json", "workspace", "create", "--name", "fallback-shell"))["value"]
    term = ws["terminal_id"]
    time.sleep(3)
    program = ("import subprocess,sys; subprocess.run([%r,'notify','--title','Deploy tag','--body','Which tag should I deploy?','--reply']);"
               " print('GOT', input())" % cmux)
    r.rig("cli", "terminal", term, "write", "--text", f"python3 -c \"{program}\"\r")
    line = None
    deadline = time.time() + 90
    while time.time() < deadline and not line:
        lines = [l for l in r.captured()[before:]
                 if json.loads(l).get("event", {}).get("kind") == "terminal"
                 and json.loads(l).get("event", {}).get("tabId")]
        line = lines[-1] if lines else None
        time.sleep(1)
    if not line:
        return record("terminal-reply", False, "the Mac host posted no terminal push", [])
    event = json.loads(line)["event"]
    sealed_for = list((event.get("sealed") or {}).keys())
    capture = os.path.join(OUT, "fallback.jsonl")
    open(capture, "w").write(line + "\n")
    outdir = os.path.join(OUT, "fallback-apns")
    subprocess.run(["rm", "-rf", outdir])
    subprocess.run(["node", os.path.join(HERE, "apns-from-capture.ts"), capture, outdir, "Rig Mac", "--phone", PHONE_LINK],
                   check=True, capture_output=True, timeout=60)
    payload = sorted(glob.glob(os.path.join(outdir, "*.json")))[-1]
    body = json.load(open(payload))
    # The phone's own copy of what APNs would bring, readable by the simulator app.
    udid = r.phone("udid").strip()
    data = subprocess.run(["xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"], capture_output=True,
                          text=True).stdout.strip()
    inbox = os.path.join(data, "tmp", "service-push.json")
    os.makedirs(os.path.dirname(inbox), exist_ok=True)
    open(inbox, "w").write(json.dumps(body))
    r.phone("terminate")
    env = dict(os.environ, SIMCTL_CHILD_CMUX_MOBILE_DEV_SERVICE_PUSH=inbox)
    subprocess.run(["xcrun", "simctl", "launch", udid, BUNDLE], env=env, capture_output=True, timeout=60)
    time.sleep(6)
    # The Mac's link goes silent (its host frozen; its terminals and daemon keep running):
    # the reply cannot use the link.
    hostd = [int(p) for p in json.loads(r.rig("status"))["hostd"]]
    for pid in hostd:
        os.kill(pid, signal.SIGSTOP)
    # Killed: the reply wakes it in the background.
    r.phone("terminate")
    r.phone("record", "start", "fallback-terminal-reply")
    r.nc()
    r.phone("shot", "fallback-banner")
    for _ in range(3):
        if "Deploy tag" in r.phone("texts"):
            break
        time.sleep(2)
        r.nc()
    r.phone("expand", "Deploy tag")
    r.phone("shot", "fallback-longlook")
    r.phone("tap", "Reply", "--kind", "Button", "--exact")
    time.sleep(1.5)
    subprocess.run(["axe", "type", "v2.4.1", "--udid", udid], check=True, timeout=60)
    time.sleep(0.5)
    r.phone("tap", "Send", "--kind", "Button", "--exact")
    time.sleep(25)
    r.phone("shot", "fallback-after-send")
    # The Mac comes back and takes its mailbox.
    for pid in hostd:
        os.kill(pid, signal.SIGCONT)
    deadline = time.time() + 120
    got = ""
    while time.time() < deadline:
        got = screen(term)
        if "got v2.4.1" in got.lower():
            break
        time.sleep(2)
    r.phone("record", "stop", check=False)
    log = r.rig("tail-log", "300")
    mailbox = [l for l in log.splitlines() if "mailbox" in l][-6:]
    ok = "got v2.4.1" in got.lower()
    record("terminal-reply", ok,
           f"sealed for {sealed_for}; banner {body['aps']['alert']}; program printed {'GOT v2.4.1' if ok else got[-160:]!r}; "
           f"host: {' | '.join(m[-140:] for m in mailbox)}",
           ["fallback-banner.png", "fallback-longlook.png", "fallback-after-send.png", "fallback-terminal-reply.mp4"])


def thaw():
    """A frozen host (a run that stopped early) never outlives the run."""
    for pid in json.loads(r.rig("status")).get("hostd", []):
        try:
            os.kill(int(pid), signal.SIGCONT)
        except ProcessLookupError:
            pass


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    thaw()
    try:
        {"terminal-reply": terminal_reply}[sys.argv[1]]()
    finally:
        thaw()
