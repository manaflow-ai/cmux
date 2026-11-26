#!/usr/bin/env python3
"""The tagged cmux NEXT Mac app, as cmux-next-ios/scripts/review.sh needs it: over its own control socket.

  review_mac.py socket APP                    the app's control socket (Info.plist LSEnvironment)
  review_mac.py bundle APP                    its bundle id
  review_mac.py wait-socket SOCK [--timeout S]
  review_mac.py account SOCK [--timeout S]    the signed-in account's email (waits for the session)
  review_mac.py mac-id SOCK [--timeout S]     the Mac's iPhone-host device id (the Settings page's `iphone`
      card in `cmux.settings.host.lists`, `device_id`), the id the phone pairs with; no file lookup that
      could name another build's state. Exit 3 with the reason when iPhone connections are off.
  review_mac.py phones SOCK                   {"paired_connected": N, "phones": [...]} (names and ids only)
  review_mac.py allow-state SOCK --phone-id ID [--phone-id ID ...] [--until asked|answered] [--timeout S]
      review.sh --approve-first: what the Mac shows for the phone with these device ids (its receipt's
      phone_device_ids), as one JSON line {"state", "mac_name", "request", "prompt", "connected"}:
      `waiting` (its request waits under Connection Requests; `prompt` is the open "Allow ... to connect?"
      dialog's title, null when none is on screen), `paired` (allowed), `gone` (a waiting request left
      without an Allow: Don't Allow, or the phone signed out), `none` (no request), `off` (iPhone
      connections off). --until asked (default) returns at the first state that is not `none`;
      --until answered returns at `paired` or `gone`, else at the deadline still `waiting`. Read only:
      the dialog list (`debug.dialog {}`) presses, types and dismisses nothing.
  review_mac.py quit SOCK                     quit as the person does, keeping sessions (quitKeepSessions)
  review_mac.py backend-check VALUE           the canonical origin --backend names, or exit 2 with the reason:
      `dev`/`development`, `preview-N`, the shared dev Workers API origin, a tailnet origin
      (https://<host>.<tailnet>.ts.net[:port]) or a tag stack's public origin (https://api.s<N>.wdev.cmux.dev);
      the app's own allowlists (Rust cmux-cloud-environment,
      iOS CloudBackendOverride) hold the same list
  review_mac.py backend-write FOLDER ORIGIN   the dev build's backend.json in its bundle folder
      (~/Library/Application Support/cmux-next/<bundle id>); an empty ORIGIN removes it. Prints
      `changed` or `same` (a running app reads it only at launch)
  review_mac.py backend SOCK [--timeout S]    the Cloud backend the running app uses (`auth.status`):
      {"backend", "backend_label", "cloud_environment", "cloud_unavailable"} as JSON
  review_mac.py space APP                     the cloud data space the installed app's requests and its
      hostd carry (`X-Cmux-Build-Space`), as the app decides it (BuildIdentity.devTag, CMUXBuildSpace):
      `dev:<slug>` for a tagged DEV or staging build, an empty line for the default space (nightly,
      release, RC), `unusable` for a DEV build with no usable tag (its requests are refused)

Nothing here turns a setting on, presses Allow or writes the app's pairing state. The phone pairs on
its own (signed in to the Mac's account); the tagged Mac's DEBUG dev auto-approve allows its own tag's
phone (cmux-next-ios/SECURITY.md "Dev auto-approve").
"""
import argparse
import json
import subprocess
import shutil
import os
import plistlib
import socket
import sys
import time
import re
import tempfile
import urllib.parse

PAGE = "cmux.settings"
DEVELOPMENT_API = "https://cmux-api-development.debussy.workers.dev"
TAILNET_LABEL = re.compile(r"^[a-z0-9-]+$")
PUBLIC_STACK = re.compile(r"api\.s[0-9]{1,3}\.wdev\.cmux\.dev")
TEAM_TAILNET_SUFFIX = ".tail137216.ts.net"


def backend_origin(value):
    """The canonical origin `value` names, or raise ValueError with the reason (the app's allowlist)."""
    raw = (value or "").strip()
    lowered = raw.lower()
    if lowered in ("dev", "development"):
        return DEVELOPMENT_API
    preview = re.fullmatch(r"preview-(\d+)", lowered)
    if preview:
        if int(preview.group(1)) == 0:
            raise ValueError("preview number must be greater than zero")
        return f"https://cmux-api-preview-{int(preview.group(1))}.debussy.workers.dev"
    url = urllib.parse.urlsplit(raw)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.path not in ("", "/") \
            or url.query or url.fragment or "@" in url.netloc:
        raise ValueError(f"not a bare https origin: {raw!r}")
    host = url.hostname.lower()
    try:
        port = url.port
    except ValueError:
        raise ValueError(f"invalid port: {raw!r}")
    suffix = f":{port}" if port else ""
    if host == "cmux-api-development.debussy.workers.dev" and not port:
        return DEVELOPMENT_API
    preview = re.fullmatch(r"cmux-api-preview-(\d+)\.debussy\.workers\.dev", host)
    if preview and not port and int(preview.group(1)) > 0:
        return f"https://cmux-api-preview-{int(preview.group(1))}.debussy.workers.dev"
    # One machine of the team's tailnet (Rust TEAM_TAILNET_SUFFIX, iOS CloudBackendOverride): another tailnet's
    # name is refused, since a Tailscale Funnel name is public.
    if host.endswith(TEAM_TAILNET_SUFFIX):
        machine = host[: -len(TEAM_TAILNET_SUFFIX)]
        if machine and TAILNET_LABEL.match(machine):
            return f"https://{host}{suffix}"
    # A tag stack's public origin (scripts/cmux-next/cloud-dev-stack/gateway): one slot's API host, no port.
    if PUBLIC_STACK.fullmatch(host) and not port:
        return f"https://{host}"
    raise ValueError(f"{raw!r} is not the shared dev deployment, a machine of the team's tailnet (*{TEAM_TAILNET_SUFFIX}) or a tag stack's public origin")


def write_backend(folder, origin):
    """backend.json in the bundle folder, atomically and private; an empty origin removes it."""
    path = os.path.join(folder, "backend.json")
    try:
        with open(path, encoding="utf-8") as f:
            before = json.load(f).get("backend", "")
    except (OSError, ValueError, AttributeError):
        before = None
    if not origin:
        if os.path.exists(path):
            os.remove(path)
            return "changed"
        return "same"
    if before == origin:
        return "same"
    os.makedirs(folder, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".backend.json.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump({"backend": origin, "written_by": "cmux-next-ios/scripts/review.sh --backend"}, f)
            f.write("\n")
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return "changed"


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


BUILD_KINDS = (("com.cmuxterm.app.debug", "dev"), ("com.cmuxterm.app.nightly", "nightly"),
               ("com.cmuxterm.app.rc", "rc"), ("com.cmuxterm.app.staging", "staging"), ("com.cmuxterm.app", "release"))
MAX_SLUG = 64


def tag_slug(raw):
    """BuildIdentity.tagSlug / CMUXBuildSpace.slug: lowercase, every run outside [a-z0-9] one `-`, trimmed."""
    slug = re.sub(r"[^a-z0-9]+", "-", (raw or "").lower()).strip("-")
    return slug or None


def build_space(plist, app_name=""):
    """The space of a Mac app with Info.plist `plist` (BuildIdentity(bundle:).devTag, then CMUXBuildSpaceState)."""
    bundle_id = str(plist.get("CFBundleIdentifier") or "").strip()
    kind, suffix = "dev", None
    for prefix, candidate in BUILD_KINDS:
        if bundle_id == prefix:
            kind = candidate
            break
        if bundle_id.startswith(prefix + "."):
            kind, suffix = candidate, bundle_id[len(prefix) + 1:]
            break
    if kind == "release" and suffix is not None:
        kind = "dev"  # com.cmuxterm.app.<other>: isolated as DEV
    if not bundle_id or kind not in ("dev", "staging"):
        return ""
    environment = plist.get("LSEnvironment") if isinstance(plist.get("LSEnvironment"), dict) else {}
    shipped = tag_slug(environment.get("CMUX_TAG"))
    if shipped is None and app_name.startswith("cmux DEV "):
        shipped = tag_slug(app_name[len("cmux DEV "):])
    tag = shipped or tag_slug(suffix)
    if tag and len(tag) > MAX_SLUG:
        return "unusable"  # rejected rather than truncated, so two tags never share one space
    if tag:
        return "dev:" + tag
    # needsBuildSpace: every DEV build (`com.cmuxterm.app.debug[.x]`) and a tagged staging build refuses
    # cloud calls without a tag.
    needs = bundle_id == "com.cmuxterm.app.debug" or bundle_id.startswith(("com.cmuxterm.app.debug.",
                                                                           "com.cmuxterm.app.staging."))
    return "unusable" if needs else ""


def info(app):
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
        return plistlib.load(f)


def status(sock):
    """The Settings page's iPhone card (`iphone` in `cmux.settings.host.lists`), {} until it answers."""
    r = rpc(sock, "debug.page", {"page": PAGE, "action": "call", "op": "cmux.settings.host.lists"})
    if "no live page" in str(r.get("error", "")):
        # A hidden Settings page (no window, nothing activated), as `debug.page open` makes one.
        rpc(sock, "debug.page", {"page": PAGE, "action": "open"})
        return {}
    value = r.get("value") if isinstance(r.get("value"), dict) else {}
    card = value.get("iphone")
    return card if isinstance(card, dict) else {}


PAIR_DIALOG = "cmux.dialog.iphonePair"


def computer_name():
    """This computer's name as the phone lists it (System Settings > General > About). The Settings page's iPhone card
    has no Mac name since the Mobile Pairing page went (#48532), and the tagged Mac app runs on this computer."""
    tool = shutil.which("scutil")
    if not tool:
        return None
    try:
        out = subprocess.run([tool, "--get", "ComputerName"], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() or None if out.returncode == 0 else None


def allow_state(sock, ids):
    """One read of what the Mac shows for the phone with device ids `ids` (lowercase): see allow-state."""
    value = status(sock)
    rows = [r for r in (value.get("phones") or []) if isinstance(r, dict) and str(r.get("id", "")).lower() in ids]
    waiting = [r for r in (value.get("pending") or []) if isinstance(r, dict) and str(r.get("id", "")).lower() in ids]
    dialogs = rpc(sock, "debug.dialog", {}, timeout=10).get("dialogs") or []
    titles = [str(d.get("title")) for d in dialogs if isinstance(d, dict) and d.get("identifier") == PAIR_DIALOG
              and d.get("visible") is not False and d.get("title")]
    # The prompt shows one waiting phone at a time: the one whose quoted name its request row has, else the first.
    name = re.search(r"“[^”]+”", str(waiting[0].get("title") or "")) if waiting else None
    prompt = next((t for t in titles if name and name.group(0) in t), titles[0] if titles else None)
    if value.get("allowed") is False:
        state = "off"
    elif any(r.get("paired") is True for r in rows):
        state = "paired"
    elif waiting:
        state = "waiting"
    else:
        state = "none" if value else "unreachable"
    return {"state": state, "mac_name": value.get("mac_name") or computer_name(),
            "request": (waiting[0].get("title") if waiting else None),
            "prompt": prompt if state == "waiting" else None,
            "connected": any(r.get("paired") is True and r.get("connected") is True for r in rows)}


def wait(fn, timeout, every=1.0):
    deadline = time.monotonic() + timeout
    while True:
        value = fn()
        if value or time.monotonic() > deadline:
            return value
        time.sleep(every)


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("op", choices=["socket", "bundle", "wait-socket", "account", "mac-id",
                                  "phones", "allow-state", "quit", "backend-check", "backend-write", "backend",
                                  "space"])
    p.add_argument("target")
    p.add_argument("value", nargs="?", default="")
    p.add_argument("--timeout", type=float, default=60)
    p.add_argument("--phone-id", action="append", default=[])
    p.add_argument("--until", default="asked", choices=["asked", "answered"])
    a = p.parse_args(argv)
    if a.op == "space":
        try:
            plist = info(a.target)
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            print(f"no readable Info.plist in {a.target} ({type(error).__name__})", file=sys.stderr)
            return 1
        print(build_space(plist, os.path.splitext(os.path.basename(a.target.rstrip("/")))[0]))
        return 0
    if a.op == "backend-check":
        try:
            print(backend_origin(a.target))
        except ValueError as error:
            print(f"--backend refused: {error}", file=sys.stderr)
            return 2
        return 0
    if a.op == "backend-write":
        if a.value:
            try:
                origin = backend_origin(a.value)
            except ValueError as error:
                print(f"--backend refused: {error}", file=sys.stderr)
                return 2
        else:
            origin = ""
        print(write_backend(a.target, origin))
        return 0
    if a.op == "backend":
        def read():
            r = rpc(a.target, "auth.status", timeout=10)
            return r if isinstance(r.get("backend"), str) and r.get("backend") else None
        r = wait(read, a.timeout, every=2)
        if not r:
            print("the tagged Mac app does not say which Cloud backend it uses", file=sys.stderr)
            return 1
        print(json.dumps({key: r.get(key) for key in ("backend", "backend_label", "cloud_environment",
                                                       "cloud_unavailable")}))
        return 0
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
    if a.op == "mac-id":
        last = {}

        def mac():
            value = status(a.target)
            if value:
                last.clear()
                last.update(value)
            found = value.get("device_id")
            return found if isinstance(found, str) and found else None
        found = wait(mac, a.timeout, every=2)
        if not found:
            if last.get("allowed") is False:
                print("iPhone connections are off on this Mac (Settings > Mobile > Allow iPhone connections)",
                      file=sys.stderr)
            else:
                print(f"the tagged Mac's iPhone host has no device id yet (phase {last.get('phase') or 'unknown'}"
                      f"{', ' + str(last.get('status')) if last.get('status') else ''})", file=sys.stderr)
            return 3
        print(found)
        return 0
    if a.op == "phones":
        value = status(a.target) or wait(lambda: status(a.target), 10, every=2) or {}
        phones = [{"id": row.get("id"), "title": row.get("title"), "paired": row.get("paired") is True,
                   "connected": row.get("connected") is True}
                  for row in (value.get("phones") or []) if isinstance(row, dict)]
        print(json.dumps({"paired_connected": sum(1 for r in phones if r["paired"] and r["connected"]), "phones": phones}))
        return 0
    if a.op == "allow-state":
        ids = {i.strip().lower() for i in a.phone_id if i.strip()}
        if not ids:
            print("allow-state needs the phone's device ids (--phone-id)", file=sys.stderr)
            return 2
        deadline = time.monotonic() + a.timeout
        while True:
            got = allow_state(a.target, ids)
            if a.until == "asked" and got["state"] not in ("none", "unreachable"):
                break
            if a.until == "answered":
                if got["state"] in ("paired", "off"):
                    break
                # The caller saw it waiting: a request that left with no Allow (Don't Allow, or the phone
                # signed out). The app keeps a request until it is answered or forgotten, also across
                # hostd's own two-minute waits, so this is not a gap between the phone's retries.
                if got["state"] == "none":
                    got["state"] = "gone"
                    break
            if time.monotonic() > deadline:
                break
            time.sleep(2)
        print(json.dumps(got, ensure_ascii=False))
        return 0
    if a.op == "quit":
        r = rpc(a.target, "action.run", {"action": "quitKeepSessions"})
        return 1 if r.get("error") else 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
