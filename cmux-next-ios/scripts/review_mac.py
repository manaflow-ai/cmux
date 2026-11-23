#!/usr/bin/env python3
"""The tagged cmux NEXT Mac app, as cmux-next-ios/scripts/review.sh needs it: over its own control socket.

  review_mac.py socket APP                    the app's control socket (Info.plist LSEnvironment)
  review_mac.py bundle APP                    its bundle id
  review_mac.py wait-socket SOCK [--timeout S]
  review_mac.py account SOCK [--timeout S]    the signed-in account's email (waits for the session)
  review_mac.py pair-url SOCK [--timeout S] [--used FILE]
      a pairing link from the Mobile Pairing page (`cmux.mobilePairing.status` `qr.url`), on stdout
      only: it carries a single-use token, so the caller keeps it in a variable and never prints it.
      A link whose hash is in FILE (one per line) already paired a phone: wait for the next. This
      only reads FILE; the caller records a link with mark-used once a phone paired with it, so a
      launch that failed, or a rerun, gets the same live code back at once. Exit 3 with the reason
      when the page cannot show one (iPhone connections off, signed out).
  review_mac.py mark-used FILE                the link on stdin paired a phone: record its hash in FILE
  review_mac.py mac-id SOCK [--timeout S]     the Mac's device id from its own pairing link (`mac=`),
      the id the phone pairs with; no file lookup that could name another build's state
  review_mac.py phones SOCK                   {"paired_connected": N, "phones": [...]} (names and ids only)
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

Nothing here turns a setting on, presses Allow or writes the app's pairing state: the code is the
Mac's own single-use invite, the same route as scanning it (cmux-next-ios/SECURITY.md, pair-e2e).
"""
import argparse
import hashlib
import json
import os
import plistlib
import socket
import sys
import time
import re
import tempfile
import urllib.parse

PAGE = "cmux.mobile-pairing"
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
    p.add_argument("op", choices=["socket", "bundle", "wait-socket", "account", "pair-url", "mark-used", "mac-id",
                                  "phones", "quit", "backend-check", "backend-write", "backend", "space"])
    p.add_argument("target")
    p.add_argument("value", nargs="?", default="")
    p.add_argument("--timeout", type=float, default=60)
    p.add_argument("--used", default="")
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
        sys.stdout.write(url + "\n")
        return 0
    if a.op == "mark-used":
        url = sys.stdin.read().strip()
        if not url:
            return 1
        with open(a.target, "a", encoding="utf-8") as f:
            f.write(hashlib.sha256(url.encode()).hexdigest() + "\n")
        return 0
    if a.op == "mac-id":
        def mac():
            value = status(a.target)
            url = (value.get("qr") or {}).get("url") if isinstance(value.get("qr"), dict) else None
            if not url:
                return None
            ids = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).get("mac") or []
            return ids[0] if ids and ids[0] else None
        found = wait(mac, a.timeout, every=2)
        if not found:
            print("the Mobile Pairing page shows no pairing code to read the Mac's device id from", file=sys.stderr)
            return 1
        print(found)
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
    return 2


if __name__ == "__main__":
    sys.exit(main())
