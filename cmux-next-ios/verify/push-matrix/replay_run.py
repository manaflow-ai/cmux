"""Runs ON the rich-push rig's mini: what a malicious cmux service can do with a captured
mailbox reply (verify/notifications-trust.md, "What the Mac checks"). It holds only what
the service holds: the sealed blobs and an account token. Each case posts to the local
Worker and reads the Mac's signed outcome.

    python3 replay_run.py replay|tamper|rebind|expired
Results: ~/richpush-verify/evidence/replay-results.json.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request
import uuid

ROOT = os.path.expanduser("~/richpush-verify")
BASE = os.environ.get("PUSHRIG_UPSTREAM", "http://127.0.0.1:8788")
CAPTURE = os.path.join(ROOT, "rig", "notify-capture-mailbox.jsonl")
RESULTS = os.path.join(ROOT, "evidence", "replay-results.json")
STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"


def env_file(path):
    out = {}
    for line in open(path):
        if "=" in line:
            k, v = line.rstrip("\n").split("=", 1)
            out[k] = v
    return out


def token():
    creds = env_file(os.path.join(ROOT, "rig", "secrets", "dev-auth.env"))
    body = json.dumps({"email": creds["CMUX_UITEST_STACK_EMAIL"], "password": creds["CMUX_UITEST_STACK_PASSWORD"]}).encode()
    req = urllib.request.Request("https://api.stack-auth.com/api/v1/auth/password/sign-in", data=body, method="POST",
                                 headers={"content-type": "application/json", "x-stack-project-id": STACK_PROJECT,
                                          "x-stack-access-type": "client",
                                          "x-stack-publishable-client-key": "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"})
    return json.load(urllib.request.urlopen(req, timeout=30))["access_token"]


def call(method, path, tok, body=None):
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"authorization": f"Bearer {tok}", "content-type": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=30)
        return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def captured():
    rows = [json.loads(l) for l in open(CAPTURE)] if os.path.exists(CAPTURE) else []
    return [r for r in rows if r.get("status") == 200 and r.get("item")]


def outcome(tok, mac, rid, wait=60):
    deadline = time.time() + wait
    state = None
    while time.time() < deadline:
        _, state = call("GET", f"/v1/devices/{mac}/mailbox/{rid}", tok)
        if state.get("state") in ("applied", "rejected", "expired"):
            return state
        time.sleep(2)
    return state


def record(row, ok, note):
    results = json.load(open(RESULTS)) if os.path.exists(RESULTS) else []
    results = [x for x in results if x["row"] != row] + [{"row": row, "pass": ok, "note": note}]
    json.dump(results, open(RESULTS, "w"), indent=1)
    print(json.dumps(results[-1]))


def main(case):
    last = captured()[-1]
    mac, item = last["mac"], last["item"]
    tok = token()
    if case == "replay":
        # The same sealed reply again, under the same id (a fresh hub that forgot it).
        status, answer = call("POST", f"/v1/devices/{mac}/mailbox", tok, item)
        state = outcome(tok, mac, item["id"])
        # A copy of a settled reply is never applied again: the Mac answers its first
        # outcome (signed), and the program's terminal shows the text once.
        term_text = "".join(subprocess.run(
            [sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "pushrig.py"), "cli", "terminal", t, "read"],
            capture_output=True, text=True, timeout=60).stdout for t in os.environ.get("REPLAY_TERMINALS", "").split(",") if t)
        once = term_text.lower().count("got v2.4.1") <= 1 if term_text else None
        ok = bool(state and state.get("state") == "applied" and state.get("sig") and once is not False)
        record("replay", ok, f"post {status} {answer}; Mac: {state}; program's terminal shows the reply once: {once}")
    elif case == "tamper":
        blob = bytearray(base64.urlsafe_b64decode(item["sealed"] + "=" * (-len(item["sealed"]) % 4)))
        blob[-20] ^= 0x01
        forged = dict(item, id=str(uuid.uuid4()), sealed=base64.urlsafe_b64encode(bytes(blob)).decode().rstrip("="))
        status, answer = call("POST", f"/v1/devices/{mac}/mailbox", tok, forged)
        state = outcome(tok, mac, forged["id"])
        record("tamper", bool(state and state.get("state") == "rejected" and state.get("reason") == "unsealed"),
               f"post {status}; Mac: {state}")
    elif case == "rebind":
        # The genuine blob under another id: the seal binds the reply's id, so it can't open.
        moved = dict(item, id=str(uuid.uuid4()))
        status, answer = call("POST", f"/v1/devices/{mac}/mailbox", tok, moved)
        state = outcome(tok, mac, moved["id"])
        record("rebind", bool(state and state.get("state") == "rejected" and state.get("reason") == "unsealed"),
               f"post {status}; Mac: {state}")
    elif case == "expired":
        # The same reply, past its window (the Mac checks expiry before replay).
        status, answer = call("POST", f"/v1/devices/{mac}/mailbox", tok, item)
        state = outcome(tok, mac, item["id"])
        record("expired", bool(state and state.get("state") == "rejected" and state.get("reason") == "expired"),
               f"captured at {last['at']}, replayed at {int(time.time() * 1000)}; post {status}; Mac: {state}")


if __name__ == "__main__":
    os.makedirs(os.path.dirname(RESULTS), exist_ok=True)
    main(sys.argv[1])
