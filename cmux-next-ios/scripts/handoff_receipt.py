#!/usr/bin/env python3
"""The cmux-next iPhone app's DEBUG readiness receipt, checked for the end-of-task hand-off.

A dev build launched with CMUX_DOGFOOD_READINESS_NONCE writes
`Library/Application Support/cmux-dogfood/readiness.json` in its data container once it is
signed in and its service answered an authenticated call (DogfoodReadiness.swift). The
receipt carries the launch's nonce, so a receipt from another launch never answers this one,
and `session_source` says how the session started: `auto_login` (credentials injected at
launch) or `restored` (no credentials: the app's own Keychain session). With a Mac named,
the receipt must also list that Mac as paired and linked, which a phone that is signed out,
never paired, or cannot reach the Mac never writes. The receipt names the phone's focused Mac, so a
phone on another Mac (another tag's dev build on the account) says which, by name and id.

  handoff_receipt.py check RECEIPT --nonce N --client-id ID --bundle-id B --account EMAIL
                    --session auto_login|restored|signed_out [--mac-id ID] [--git-sha SHA] [--dev-tag TAG]
      signed_out (--no-auth): the receipt says signed out and names no account or Mac; for the
      other sessions a signed-out receipt means "not yet" (exit 1)
      --build-space SPACE: the receipt's build_space (the cloud data space the app's requests carry) must
      be SPACE, the tagged Mac's (review_mac.py space); another space is refused at once (exit 3), since
      a phone in another space never lists its tag's Mac
      --git-sha / --dev-tag: the receipt must come from the build of this run's head and tag
      (Info.plist CmuxMobileSourceCommit, CmuxMobileTag), not an older install of the bundle.
      exit 0: valid (prints one line); 1: not this launch's yet (keep waiting);
      3: this launch's receipt, and wrong (stop waiting; prints why)
  handoff_receipt.py phone-ids RECEIPT
      the phone's device ids (phone_device_ids), one per line: the ids its Mac lists it by
  handoff_receipt.py env-value FILE KEY
      one KEY=VALUE line of a credentials file, printed (for a child's environment only)
  handoff_receipt.py check-zip ZIP
      exit 1 (reason on stderr) for an entry with an absolute path or `..`, or a symlink pointing
      outside the archive (absolute, or climbing out of it); links inside it are fine
  handoff_receipt.py read-manifest HANDOFF_JSON --tag T --sha S --bundle-id B
      the fleet step's handoff.json, checked against this run, as four lines: simulator status, host,
      simulator device, reason (an empty field is an empty line); exit 1 with the mismatch on stderr
  handoff_receipt.py manifest OUT --tag ... --sha ... --bundle-id ... --host ...
                    --simulator ... --sim-status pass|fail --sim-reason TEXT
      the fleet step's handoff.json

Its tests: python3 ios/tests/test_cnx_review.py (ReceiptCheckTests)
"""
import argparse
from urllib.parse import urlparse
import json
import os
import posixpath
import stat
import sys
import zipfile

FORBIDDEN = ("token", "password", "secret", "cookie")


def retry(reason):
    print(reason)
    raise SystemExit(1)


def reject(reason):
    print(reason)
    raise SystemExit(3)


def check(a):
    try:
        with open(a.receipt, encoding="utf-8") as f:
            receipt = json.load(f)
    except (OSError, ValueError):
        retry("no readable receipt yet")
    if not isinstance(receipt, dict):
        retry("the receipt is not a JSON object yet")
    if not a.nonce or receipt.get("nonce") != a.nonce:
        retry("the receipt is from another launch (nonce)")
    for key in receipt:
        if any(word in str(key).lower() for word in FORBIDDEN):
            reject(f"the receipt carries a secret-like field: {key}")
    if receipt.get("schema") != 1 or isinstance(receipt.get("schema"), bool):
        reject("the receipt has an unsupported schema")
    for key in ("client_id", "bundle_id", "session_source", "written_at"):
        if not isinstance(receipt.get(key), str) or not receipt[key]:
            reject(f"the receipt has no {key}")
    if receipt["client_id"] != a.client_id:
        reject("the receipt names another client id (another phone or simulator)")
    if receipt["bundle_id"] != a.bundle_id:
        reject(f"the receipt is from {receipt['bundle_id']}, not {a.bundle_id}")
    if a.build_space is not None:
        have = receipt.get("build_space")
        if not isinstance(have, str):
            reject("the receipt names no build_space (an app from before build spaces)")
        if have != a.build_space:
            reject(f"the app's build space is {have or 'the default space'!r}, not the tagged Mac's "
                   f"{a.build_space or 'the default space'!r}: it lists none of that Mac's devices")
    for key, want in (("git_sha", a.git_sha), ("dev_tag", a.dev_tag)):
        if want and receipt.get(key) != want:
            reject(f"the installed app is another build: its {key} is {receipt.get(key)!r}, this run's is {want!r}")
    # review.sh --backend: the app uses the tag's backend (on its first launch and, kept, on every later one).
    if a.cloud_backend:
        have = receipt.get("cloud_backend")
        if not isinstance(have, str) or not have:
            reject("the receipt names no cloud_backend (a build from before review.sh --backend)")
        if a.cloud_backend == "default":
            # The build's own backend: an override review.sh or the app kept from an earlier run (a tag's
            # stack or a preview) must be gone.
            host = (urlparse(have).hostname or "").lower()
            if host.endswith(".ts.net") or host.endswith(".wdev.cmux.dev") or host.startswith("cmux-api-preview-"):
                reject(f"the app still uses the kept Cloud backend {have}")
        elif have.rstrip("/").lower() != a.cloud_backend.rstrip("/").lower():
            reject(f"the app uses the Cloud backend {have}, not {a.cloud_backend}")
    # A tag's stack (review.sh --backend tag-stack) brings its own mobile Worker, where the tag's Mac registers:
    # the phone must use it too (CloudBackendOverride.mobileAPI), or it never finds that Mac.
    if a.mobile_api:
        have = receipt.get("api_base_url")
        if not isinstance(have, str) or have.rstrip("/").lower() != a.mobile_api.rstrip("/").lower():
            reject(f"the app uses the mobile service {have or 'none'}, not the tag stack's {a.mobile_api}")
    signed_out = receipt.get("signed_in") is False or receipt["session_source"] == "signed_out"
    if a.session == "signed_out":
        # --no-auth: the app must sit at the welcome screen, signed in to no account.
        if not signed_out:
            reject(f"the app is signed in ({receipt['session_source']}), expected signed out")
        if receipt.get("account_email") or receipt.get("user_id") or receipt.get("paired_macs"):
            reject("a signed-out receipt names an account or a Mac")
        print("signed out (at the welcome screen)")
        return 0
    if signed_out:
        # A launch resolves signed out before an auto-login or restore finishes: keep waiting.
        retry("the app is signed out (so far)")
    for key in ("account_email", "user_id"):
        if not isinstance(receipt.get(key), str) or not receipt[key]:
            reject(f"the receipt has no {key}")
    if receipt["account_email"].strip().lower() != a.account.strip().lower():
        reject("the app is signed in to another account than the selected profile")
    if receipt["session_source"] != a.session:
        reject(f"the session is {receipt['session_source']}, expected {a.session}"
               + (" (a credential-free relaunch signed in again instead of restoring)" if a.session == "restored" else ""))
    line = f"signed in ({a.session})"
    if a.mac_id:
        macs = receipt.get("paired_macs")
        if not isinstance(macs, list):
            reject("the receipt lists no paired Macs")
        mine = [m for m in macs if isinstance(m, dict) and m.get("id") == a.mac_id]
        if not mine:
            # The phone is on another Mac (another tag's dev build on the same account, say): a launch
            # with a code may first link the Mac it remembered, so this keeps waiting, and at the
            # deadline review.sh fails with this line.
            named = [m for m in macs if isinstance(m, dict) and m.get("id")]
            # The Mac it is linked with, else the first it lists.
            other = next((m for m in named if m.get("linked") is True), named[0] if named else None)
            if other:
                state = "linked with" if other.get("linked") is True else "on"
                retry(f"{state} another Mac, not this tag's: {other.get('name') or '?'} ({other['id']}), "
                      f"not the tagged Mac {a.mac_id} (the phone chose another build on the account)")
            # Pairing finishes after sign-in: until the deadline this launch may still pair.
            retry(f"not paired with the tagged Mac yet ({len(macs)} other paired Mac(s))")
        if mine[0].get("linked") is not True:
            retry("paired with the tagged Mac, not linked yet")
        line += f", paired and linked with {mine[0].get('name') or a.mac_id}"
    print(line)
    return 0


def phone_ids(a):
    try:
        ids = json.load(open(a.receipt, encoding="utf-8")).get("phone_device_ids")
    except (OSError, ValueError, AttributeError):
        return 1
    if not isinstance(ids, list) or not all(isinstance(i, str) and i for i in ids) or not ids:
        return 1
    print("\n".join(ids))
    return 0


def check_zip(a):
    try:
        with zipfile.ZipFile(a.zip) as z:
            for info in z.infolist():
                name = info.filename
                parts = name.split("/")
                if name.startswith("/") or ".." in parts:
                    print(f"unsafe path in the archive: {name}", file=sys.stderr)
                    return 1
                if stat.S_ISLNK(info.external_attr >> 16):
                    target = z.read(info).decode("utf-8", "replace")
                    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                    if target.startswith("/") or resolved == ".." or resolved.startswith("../"):
                        print(f"symlink out of the archive: {name} -> {target}", file=sys.stderr)
                        return 1
    except (OSError, zipfile.BadZipFile) as error:
        print(f"not a readable zip ({error})", file=sys.stderr)
        return 1
    return 0


def read_manifest(a):
    try:
        m = json.load(open(a.manifest, encoding="utf-8"))
    except (OSError, ValueError) as error:
        print(f"handoff.json is missing or unreadable ({type(error).__name__})", file=sys.stderr)
        return 1
    if not isinstance(m, dict):
        print("handoff.json is not a JSON object", file=sys.stderr)
        return 1
    want = {"kind": "cmux-next-ios-handoff", "tag": a.tag, "source_sha": a.sha, "bundle_id": a.bundle_id}
    bad = [f"{k} is {m.get(k)!r}, expected {v!r}" for k, v in want.items() if m.get(k) != v]
    if bad:
        print("handoff.json does not match this run: " + "; ".join(bad), file=sys.stderr)
        return 1
    sim = m.get("simulator") if isinstance(m.get("simulator"), dict) else {}
    for value in (sim.get("status"), m.get("host"), sim.get("device"), sim.get("reason")):
        print(" ".join(str(value or "").split()))
    return 0


def env_value(a):
    # KEY=VALUE lines, optionally `export`ed and quoted; never sourced (it is data, not a script).
    try:
        lines = open(a.file, encoding="utf-8").read().splitlines()
    except OSError:
        return 1
    for line in lines:
        line = line.strip()
        if line.startswith("export "):
            line = line[len("export "):].strip()
        key, sep, value = line.partition("=")
        if sep and key.strip() == a.key:
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
                value = value[1:-1]
            if not value:
                return 1
            sys.stdout.write(value + "\n")
            return 0
    return 1


def manifest(a):
    body = {"schema": 1, "kind": "cmux-next-ios-handoff", "tag": a.tag, "source_sha": a.sha,
            "bundle_id": a.bundle_id, "configuration": "Demo", "host": a.host,
            "device_app": "CmuxMobileApp-Demo-device-unsigned.app.zip",
            "simulator_app": "CmuxMobileApp-Demo-simulator.app.zip", "signed": False,
            "simulator": {"device": a.simulator, "status": a.sim_status or "fail",
                          "reason": a.sim_reason or ("" if a.sim_status == "pass" else "not run"),
                          "screens": ["screens/signed-in-auto_login.png", "screens/signed-in-restored.png"],
                          "recording": "recording.mp4"}}
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(body, f, indent=2, sort_keys=True)
        f.write("\n")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="op", required=True)
    c = sub.add_parser("check")
    c.add_argument("receipt")
    for flag in ("--nonce", "--client-id", "--bundle-id"):
        c.add_argument(flag, required=True)
    c.add_argument("--account", default="")
    c.add_argument("--session", required=True, choices=["auto_login", "restored", "signed_out"])
    c.add_argument("--mac-id", default="")
    c.add_argument("--git-sha", default="")
    c.add_argument("--dev-tag", default="")
    c.add_argument("--cloud-backend", default="")
    c.add_argument("--mobile-api", default="")
    c.add_argument("--build-space", default=None)
    i = sub.add_parser("phone-ids")
    i.add_argument("receipt")
    e = sub.add_parser("env-value")
    e.add_argument("file")
    e.add_argument("key")
    z = sub.add_parser("check-zip")
    z.add_argument("zip")
    r = sub.add_parser("read-manifest")
    r.add_argument("manifest")
    for flag in ("--tag", "--sha", "--bundle-id"):
        r.add_argument(flag, required=True)
    m = sub.add_parser("manifest")
    m.add_argument("out")
    for flag in ("--tag", "--sha", "--bundle-id", "--host", "--simulator", "--sim-status", "--sim-reason"):
        m.add_argument(flag, default="")
    a = p.parse_args(argv)
    return {"check": check, "phone-ids": phone_ids, "check-zip": check_zip, "read-manifest": read_manifest,
            "env-value": env_value, "manifest": manifest}[a.op](a)


if __name__ == "__main__":
    sys.exit(main())
