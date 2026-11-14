#!/usr/bin/env python3
"""The tagged cmux NEXT Mac app, as cmux-next-ios/scripts/review.sh needs it: over its own control socket.

  review_mac.py socket APP                    the app's control socket (Info.plist LSEnvironment)
  review_mac.py bundle APP                    its bundle id
  review_mac.py wait-socket SOCK [--timeout S]
  review_mac.py account SOCK [--timeout S]    the signed-in account's email (waits for the session)
  review_mac.py pair-url SOCK [--timeout S] [--used FILE]
      a fresh pairing link from the Mobile Pairing page (`cmux.mobilePairing.status` `qr.url`), on
      stdout only: it carries a single-use token, so the caller keeps it in a variable and never
      prints it. A link whose hash is in FILE (one per line) was given to another phone: wait for the
      next. Exit 3 with the reason when the page cannot show one (iPhone connections off, signed out).
  review_mac.py phones SOCK                   {"paired_connected": N, "phones": [...]} (names and ids only)
  review_mac.py quit SOCK                     quit as the person does, keeping sessions (quitKeepSessions)
  review_mac.py device-id BUNDLE_ID           this Mac's cmux-mobile-host device id for the bundle

Nothing here turns a setting on, presses Allow or writes the app's pairing state: the code is the
Mac's own single-use invite, the same route as scanning it (cmux-next-ios/SECURITY.md, pair-e2e).
"""
import argparse
import glob
import hashlib
import json
import os
import plistlib
import socket
import sys
import time

PAGE = "cmux.mobile-pairing"


def rpc(sock, method, params=None, timeout=30):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(sock)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    if not reply.get("ok"):
        return {"error": reply.get("error")}
    result = reply.get("result")
    return result if isinstance(result, dict) else {"result": result}


def info(app):
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
        return plistlib.load(f)


def status(sock):
    r = rpc(sock, "debug.page", {"page": PAGE, "action": "call", "op": "cmux.mobilePairing.status"})
    if "no live page" in str(r.get("error", "")):
        # The page opens in the tagged app's window without activating the app.
        rpc(sock, "action.run", {"action": "palette.mobileConnect", "focus": False})
        return {}
    return r.get("value") if isinstance(r.get("value"), dict) else {}


def wait(fn, timeout, every=1.0):
    deadline = time.monotonic() + timeout
    while True:
        value = fn()
        if value or time.monotonic() > deadline:
            return value
        time.sleep(every)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("op", choices=["socket", "bundle", "wait-socket", "account", "pair-url", "phones", "quit", "device-id"])
    p.add_argument("target")
    p.add_argument("--timeout", type=float, default=60)
    p.add_argument("--used", default="")
    a = p.parse_args(argv)
    if a.op == "socket":
        env = info(a.target).get("LSEnvironment") or {}
        print(env.get("CMUX_SOCKET_PATH") or "")
        return 0 if env.get("CMUX_SOCKET_PATH") else 1
    if a.op == "bundle":
        print(info(a.target).get("CFBundleIdentifier", ""))
        return 0
    if a.op == "wait-socket":
        ok = wait(lambda: os.path.exists(a.target) and "error" not in rpc(a.target, "auth.status", timeout=5), a.timeout)
        return 0 if ok else 1
    if a.op == "account":
        def signed_in():
            r = rpc(a.target, "auth.status", timeout=10)
            email, user = r.get("email"), r.get("user")
            if not (isinstance(email, str) and email.strip()) and isinstance(user, dict):
                email = user.get("email")
            return email.strip().lower() if r.get("signed_in") is True and isinstance(email, str) and email.strip() else None
        email = wait(signed_in, a.timeout, every=2)
        if not email:
            print("the tagged Mac app is not signed in", file=sys.stderr)
            return 1
        print(email)
        return 0
    if a.op == "pair-url":
        used = set()
        if a.used and os.path.exists(a.used):
            used = {line.strip() for line in open(a.used, encoding="utf-8") if line.strip()}
        last = {}

        def fresh():
            value = status(a.target)
            if value:
                last.clear()
                last.update(value)
            url = (value.get("qr") or {}).get("url") if isinstance(value.get("qr"), dict) else None
            if url and hashlib.sha256(url.encode()).hexdigest() not in used:
                return url
            return None
        url = wait(fresh, a.timeout, every=2)
        if not url:
            if last.get("allowed") is False:
                print("iPhone connections are off on this Mac (Settings > Mobile > Allow iPhone connections); only the "
                      "person turns them on", file=sys.stderr)
            else:
                print(f"the Mobile Pairing page shows no new code (state {last.get('state') or 'unknown'}"
                      f"{', ' + str(last.get('failure')) if last.get('failure') else ''})", file=sys.stderr)
            return 3
        if a.used:
            with open(a.used, "a", encoding="utf-8") as f:
                f.write(hashlib.sha256(url.encode()).hexdigest() + "\n")
        sys.stdout.write(url + "\n")
        return 0
    if a.op == "phones":
        value = status(a.target) or wait(lambda: status(a.target), 10, every=2) or {}
        phones = [{"id": row.get("id"), "title": row.get("title"), "paired": row.get("paired") is True,
                   "connected": row.get("connected") is True}
                  for row in ((value.get("host") or {}).get("phones") or []) if isinstance(row, dict)]
        print(json.dumps({"paired_connected": sum(1 for r in phones if r["paired"] and r["connected"]), "phones": phones}))
        return 0
    if a.op == "quit":
        r = rpc(a.target, "action.run", {"action": "quitKeepSessions"})
        return 1 if r.get("error") else 0
    if a.op == "device-id":
        root = os.path.expanduser(os.path.join("~/Library/Application Support", a.target))
        for path in sorted(glob.glob(os.path.join(root, "cmux-mobile-host", "device-id"))
                           + glob.glob(os.path.join(root, "*", "cmux-mobile-host", "device-id"))):
            value = open(path, encoding="utf-8").read().strip()
            if value:
                print(value)
                return 0
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
