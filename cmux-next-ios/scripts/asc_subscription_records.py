#!/usr/bin/env python3
"""Bring the App Store record's subscriptions up to what App Review needs.

`asc validate --strict` (ios-app-review-readiness.yml, App Store Connect
verdict) blocks on three subscription findings this script can fix from the
repo:

  subscriptions.diagnostics.review_screenshot_missing  no App Review screenshot
  subscriptions.images.recommended                      no promotional image
  subscriptions.review_readiness.needs_attention        MISSING_METADATA (one
                                                         of the above, a
                                                         localization, a price
                                                         or availability)

The inputs sit beside the listing, in cmux-next-ios/AppStoreReview/subscriptions/:
records.json names each subscription by product id with its review screenshot,
its promotional image (1024x1024, RGB, no alpha) and its localizations.

Subcommands, all through the public App Store Connect API with the CI key
(asc_review_package.py's client and auth):

  plan   Read every listed subscription and print what is missing and what
         `apply` would write. Writes nothing. The default.
  apply  Write only what `plan` prints: create a missing localization, upload a
         missing review screenshot or promotional image. Idempotent: anything
         present is left alone, so a second run writes nothing.

Never written: prices, availability, territories, submissions, deletions, or
anything on a subscription records.json does not list. A missing price or
availability is printed as a person's step (it is money). A subscription that
is READY_TO_SUBMIT is complete; it goes to App Review with the next app version
submission, which is a person's step too.

Retired subscriptions (records.json "retired") are never written: App Store
Connect cannot delete them and they are never sold, so app_review_gate.py
reports their findings as notes, not blockers (RETIRED_SUBSCRIPTIONS there).

A file records.json names that is not checked in yet (the App Review
screenshot of the Plans screen, until one is captured) holds back only that
write: plan prints it as "waiting", and the rest still runs. A file that is
there but wrong (not a PNG, a promotional image that is not 1024x1024 RGB) stops
the run before any request.

Output: one line per subscription and action, and with --json a summary the
workflow uploads. Exit 1 when a write failed or an input file is wrong.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
import urllib.request
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from asc_review_package import Api, PackageError  # noqa: E402

IOS_DIR = Path(__file__).resolve().parents[1]
RECORDS_DIR = IOS_DIR / "AppStoreReview" / "subscriptions"
RECORDS_FILE = RECORDS_DIR / "records.json"
PROMO_SIZE = (1024, 1024)


def load_records(path: Path = RECORDS_FILE) -> dict:
    body = json.loads(path.read_text())
    subs = body.get("subscriptions") or []
    seen: set[str] = set()
    for sub in subs:
        pid = sub["productId"]
        if pid in seen:
            raise PackageError(f"{pid} listed twice in {path.name}")
        seen.add(pid)
    retired = {r["productId"] for r in body.get("retired") or []}
    if retired & seen:
        raise PackageError(f"retired and listed: {sorted(retired & seen)}")
    return body


def png_info(path: Path) -> tuple[int, int, int]:
    """Width, height and PNG color type (2 = RGB, 6 = RGBA)."""
    head = path.read_bytes()[:26]
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        raise PackageError(f"{path.name} is not a PNG")
    width, height = struct.unpack(">II", head[16:24])
    return width, height, head[25]


def check_inputs(records: dict, root: Path = RECORDS_DIR) -> list[str]:
    """Checked-in files that are wrong, before any request. A file that is
    not checked in yet is no problem here: plan_for holds back its write."""
    problems = []
    for sub in records.get("subscriptions") or []:
        for key in ("reviewScreenshot", "promotionalImage"):
            name = sub.get(key)
            if not name:
                problems.append(f"{sub['productId']}: no {key} in records.json")
                continue
            path = root / name
            if not path.is_file():
                continue
            try:
                width, height, color = png_info(path)
            except PackageError as error:
                problems.append(f"{sub['productId']}: {error}")
                continue
            if key == "promotionalImage" and ((width, height) != PROMO_SIZE or color != 2):
                problems.append(f"{sub['productId']}: {name} is {width}x{height} color type {color}; "
                                "a promotional image is 1024x1024 RGB with no alpha")
    return problems


# --- reads -------------------------------------------------------------------


def app_subscriptions(api: Api, app: str) -> dict[str, dict]:
    """Every subscription on the app's record, by product id."""
    out: dict[str, dict] = {}
    for group in api.get_all(f"/v1/apps/{app}/subscriptionGroups?limit=50"):
        for sub in api.get_all(f"/v1/subscriptionGroups/{group['id']}/subscriptions?limit=50"):
            out[sub["attributes"]["productId"]] = sub
    return out


def asset_done(asset: dict | None) -> bool:
    state = ((asset or {}).get("attributes") or {}).get("assetDeliveryState") or {}
    return state.get("state") in ("COMPLETE", "UPLOAD_COMPLETE")


def read_state(api: Api, sub: dict) -> dict:
    sid = sub["id"]
    shot = api.get(f"/v1/subscriptions/{sid}/appStoreReviewScreenshot").get("data")
    images = api.get_all(f"/v1/subscriptions/{sid}/images?limit=50")
    locs = api.get_all(f"/v1/subscriptions/{sid}/subscriptionLocalizations?limit=50")
    prices = api.get(f"/v1/subscriptions/{sid}/prices?limit=1").get("data") or []
    try:
        availability = api.get(f"/v1/subscriptions/{sid}/subscriptionAvailability").get("data")
    except PackageError:
        availability = None
    return {
        "id": sid,
        "state": sub["attributes"].get("state", ""),
        "reviewScreenshot": shot,
        "images": images,
        "locales": {(loc.get("attributes") or {}).get("locale") for loc in locs},
        "hasPrice": bool(prices),
        "hasAvailability": bool(availability),
    }


def plan_for(listed: dict, state: dict, root: Path = RECORDS_DIR) -> tuple[list[dict], list[str], list[str]]:
    """The writes `apply` makes, the gaps only a person closes, and the writes
    waiting on a file that is not checked in yet."""
    writes: list[dict] = []
    person: list[str] = []
    waiting: list[str] = []

    def upload(kind: str) -> None:
        name = listed[kind]
        if (root / name).is_file():
            writes.append({"kind": kind, "file": name})
        else:
            waiting.append(f"{kind} {name} is not checked in under AppStoreReview/subscriptions/")

    shot = state["reviewScreenshot"]
    if shot is None:
        upload("reviewScreenshot")
    elif not asset_done(shot):
        person.append("its App Review screenshot upload never completed; replace it in App Store Connect")
    if not any(asset_done(image) for image in state["images"]):
        if state["images"]:
            person.append("its promotional image upload never completed; replace it in App Store Connect")
        else:
            upload("promotionalImage")
    for locale, text in sorted((listed.get("localizations") or {}).items()):
        if locale not in state["locales"]:
            writes.append({"kind": "localization", "locale": locale, "name": text["name"],
                           "description": text.get("description", "")})
    if not state["hasPrice"]:
        person.append("no price (set it in App Store Connect; prices are never written here)")
    if not state["hasAvailability"]:
        person.append("no availability (set its territories in App Store Connect)")
    if state["state"] == "READY_TO_SUBMIT":
        person.append("READY_TO_SUBMIT: complete; it goes to App Review with the next app version submission")
    return writes, person, waiting


# --- writes ------------------------------------------------------------------


def upload_asset(api: Api, kind: str, sid: str, path: Path) -> str:
    """Reserve, upload and commit one asset; returns its id."""
    data = path.read_bytes()
    created = api.request("POST", f"/v1/{kind}", {"data": {
        "type": kind,
        "attributes": {"fileName": path.name, "fileSize": len(data)},
        "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sid}}},
    }})["data"]
    for op in created["attributes"].get("uploadOperations") or []:
        start, length = int(op.get("offset", 0)), int(op["length"])
        req = urllib.request.Request(op["url"], data=data[start:start + length], method=op.get("method", "PUT"))
        for header in op.get("requestHeaders") or []:
            req.add_header(header["name"], header["value"])
        with urllib.request.urlopen(req, timeout=api.timeout) as resp:
            resp.read()
    api.request("PATCH", f"/v1/{kind}/{created['id']}", {"data": {
        "type": kind, "id": created["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()},
    }})
    return created["id"]


def apply_write(api: Api, sid: str, write: dict, root: Path = RECORDS_DIR) -> str:
    if write["kind"] == "reviewScreenshot":
        return upload_asset(api, "subscriptionAppStoreReviewScreenshots", sid, root / write["file"])
    if write["kind"] == "promotionalImage":
        return upload_asset(api, "subscriptionImages", sid, root / write["file"])
    if write["kind"] == "localization":
        attributes = {"locale": write["locale"], "name": write["name"]}
        if write["description"]:
            attributes["description"] = write["description"]
        return api.request("POST", "/v1/subscriptionLocalizations", {"data": {
            "type": "subscriptionLocalizations", "attributes": attributes,
            "relationships": {"subscription": {"data": {"type": "subscriptions", "id": sid}}},
        }})["data"]["id"]
    raise PackageError(f"unknown write {write['kind']}")


def describe(write: dict) -> str:
    if write["kind"] == "localization":
        return f"create localization {write['locale']} ({write['name']!r})"
    return f"upload {write['kind']} {write['file']}"


def run(api: Api, app: str, records: dict, apply: bool, root: Path = RECORDS_DIR) -> dict:
    on_record = app_subscriptions(api, app)
    summary: dict[str, Any] = {"apply": apply, "subscriptions": [], "failed": 0, "written": 0, "planned": 0,
                               "waiting": 0}
    for listed in records.get("subscriptions") or []:
        pid = listed["productId"]
        entry: dict[str, Any] = {"productId": pid}
        sub = on_record.get(pid)
        if sub is None:
            entry["error"] = "not on the App Store record"
            summary["failed"] += 1
            print(f"{pid}: not on the App Store record")
            summary["subscriptions"].append(entry)
            continue
        state = read_state(api, sub)
        writes, person, waiting = plan_for(listed, state, root)
        entry.update(state=state["state"], writes=[describe(w) for w in writes], person=person, waiting=waiting)
        summary["planned"] += len(writes)
        summary["waiting"] += len(waiting)
        print(f"{pid} ({state['state']}): {len(writes)} write(s), {len(waiting)} waiting, {len(person)} person step(s)")
        for write in writes:
            line = describe(write)
            if not apply:
                print(f"  plan: {line}")
                continue
            try:
                apply_write(api, state["id"], write, root)
                summary["written"] += 1
                print(f"  wrote: {line}")
            except (PackageError, OSError) as error:
                summary["failed"] += 1
                print(f"  FAILED: {line}: {error}")
        for line in waiting:
            print(f"  waiting: {line}")
        for step in person:
            print(f"  person: {step}")
        summary["subscriptions"].append(entry)
    for retired in records.get("retired") or []:
        print(f"{retired['productId']}: retired, never written ({retired['why']})")
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("command", nargs="?", choices=("plan", "apply"), default="plan")
    parser.add_argument("--app", required=True, help="App Store Connect app id")
    parser.add_argument("--records", default=str(RECORDS_FILE))
    parser.add_argument("--json", help="write the summary here")
    args = parser.parse_args(argv)
    records_path = Path(args.records)
    try:
        records = load_records(records_path)
        problems = check_inputs(records, records_path.parent)
        for problem in problems:
            print(f"input: {problem}", file=sys.stderr)
        if problems:
            return 1
        summary = run(Api(), args.app, records, args.command == "apply", records_path.parent)
    except PackageError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    if args.json:
        Path(args.json).write_text(json.dumps(summary, indent=2) + "\n")
    return 1 if summary["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
