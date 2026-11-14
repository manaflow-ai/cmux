#!/usr/bin/env python3
"""The cmux-next iPhone app's DEBUG readiness receipt, checked for the end-of-task hand-off.

A dev build launched with CMUX_DOGFOOD_READINESS_NONCE writes
`Library/Application Support/cmux-dogfood/readiness.json` in its data container once it is
signed in and its service answered an authenticated call (DogfoodReadiness.swift). The
receipt carries the launch's nonce, so a receipt from another launch never answers this one,
and `session_source` says how the session started: `auto_login` (credentials injected at
launch) or `restored` (no credentials: the app's own Keychain session). With a Mac named,
the receipt must also list that Mac as paired and linked, which a phone that is signed out,
never paired, or cannot reach the Mac never writes.

  handoff_receipt.py check RECEIPT --nonce N --client-id ID --bundle-id B --account EMAIL
                    --session auto_login|restored [--mac-id ID]
      exit 0: valid (prints one line); 1: not this launch's yet (keep waiting);
      3: this launch's receipt, and wrong (stop waiting; prints why)
  handoff_receipt.py env-value FILE KEY
      one KEY=VALUE line of a credentials file, printed (for a child's environment only)
  handoff_receipt.py manifest OUT --tag ... --sha ... --bundle-id ... --host ...
                    --simulator ... --sim-status pass|fail --sim-reason TEXT
      the fleet step's handoff.json

Run its tests: python3 cmux-next-ios/scripts/test_handoff_receipt.py
"""
import argparse
import json
import os
import sys

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
    for key in ("client_id", "bundle_id", "account_email", "user_id", "session_source", "written_at"):
        if not isinstance(receipt.get(key), str) or not receipt[key]:
            reject(f"the receipt has no {key}")
    if receipt["client_id"] != a.client_id:
        reject("the receipt names another client id (another phone or simulator)")
    if receipt["bundle_id"] != a.bundle_id:
        reject(f"the receipt is from {receipt['bundle_id']}, not {a.bundle_id}")
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
            # Pairing finishes after sign-in: until the deadline this launch may still pair.
            retry(f"not paired with the tagged Mac yet ({len(macs)} other paired Mac(s))")
        if mine[0].get("linked") is not True:
            retry("paired with the tagged Mac, not linked yet")
        line += f", paired and linked with {mine[0].get('name') or a.mac_id}"
    print(line)
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
    for flag in ("--nonce", "--client-id", "--bundle-id", "--account"):
        c.add_argument(flag, required=True)
    c.add_argument("--session", required=True, choices=["auto_login", "restored"])
    c.add_argument("--mac-id", default="")
    e = sub.add_parser("env-value")
    e.add_argument("file")
    e.add_argument("key")
    m = sub.add_parser("manifest")
    m.add_argument("out")
    for flag in ("--tag", "--sha", "--bundle-id", "--host", "--simulator", "--sim-status", "--sim-reason"):
        m.add_argument(flag, default="")
    a = p.parse_args(argv)
    return {"check": check, "env-value": env_value, "manifest": manifest}[a.op](a)


if __name__ == "__main__":
    sys.exit(main())
