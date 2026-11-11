#!/usr/bin/env python3
"""Keep the App Store Connect review package in step with cmux-next-ios/AppStoreReview.

cmux-next-ios ships under the production App Store record and replaces the
classic app as an update. This script and the package it reads sit beside the
app they describe, and every path is taken from this file's own location, so a
workflow on any branch can check out feat-cmux-next anywhere and run
`python3 <checkout>/cmux-next-ios/scripts/asc_review_package.py ...`.

Subcommands, all through the public App Store Connect API with the CI key:

  sync-notes          Render AppStoreReview/review-notes-asc.txt and write it to
                      the version's App Review notes. The demo account, public
                      inbox and contact come from App Store Connect; the values
                      App Store Connect has no field for come from the
                      environment (REVIEW_ENV_VALUES). Any placeholder left empty
                      fails the run before anything is written, so live values
                      never live in git and unfilled notes never reach a
                      reviewer. Template lines starting with "##" are notes for
                      maintainers and are dropped.
  sync-listing        Set every locale of the version to the Support URL in
                      metadata/version/<version>/en-US.json, then read them back
                      and fail on any locale that still differs (a locale left
                      on the home page is a Guideline 1.5 rejection).

--version defaults to MARKETING_VERSION in cmux-next-ios/project.yml. The rest
of the listing (description, subtitle, keywords, promotional text) is pushed with
`asc metadata apply --dir cmux-next-ios/AppStoreReview/metadata`.

Auth: ASC_API_KEY_ID, ASC_API_ISSUER_ID and ASC_API_KEY_PATH or
ASC_API_KEY_P8_BASE64 (the production lane's names), or ASC_KEY_ID, ASC_ISSUER_ID
and ASC_PRIVATE_KEY_PATH (the INTERNAL builder's names). The JWT is signed with
openssl, so no Python package is installed next to the key.

The app sells no digital goods, so there is no subscription step here.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

OFFICIAL_API_BASE = "https://api.appstoreconnect.apple.com"
IOS_DIR = Path(__file__).resolve().parents[1]
PROJECT_YML = IOS_DIR / "project.yml"
REVIEW_DIR = IOS_DIR / "AppStoreReview"
DEFAULT_NOTES_TEMPLATE = REVIEW_DIR / "review-notes-asc.txt"
METADATA_DIR = REVIEW_DIR / "metadata"
VERSION_METADATA_DIR = METADATA_DIR / "version"
NOTES_LIMIT = 4000
PLACEHOLDER = re.compile(r"\{\{([A-Z_]+)\}\}")
TEMPLATE_COMMENT = re.compile(r"^##.*(?:\n|$)", re.MULTILINE)
MAILINATOR_URL = re.compile(r"https?://(?:www\.)?mailinator\.com/[^\s)]+", re.IGNORECASE)
# Placeholders App Store Connect has no field for, by the environment variable
# that carries each (the App Store workflow maps them from repository variables).
REVIEW_ENV_VALUES = {
    "REVIEW_CHIEF_NAME": "CMUX_IOS_REVIEW_CHIEF_NAME",
}


class PackageError(RuntimeError):
    pass


def note(message: str) -> None:
    print(f"asc-review-package: {message}", file=sys.stderr)


def marketing_version(project_yml: Path = PROJECT_YML) -> str:
    match = re.search(r"^\s*MARKETING_VERSION:\s*\"?([0-9][0-9.]*)\"?\s*$", project_yml.read_text(encoding="utf-8"), re.MULTILINE)
    if not match:
        raise PackageError(f"{project_yml}: no MARKETING_VERSION")
    return match.group(1)


# --- auth ------------------------------------------------------------------


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _der_to_raw(der: bytes) -> bytes:
    """ECDSA DER signature to the JWS r||s form (32 bytes each)."""
    if len(der) < 8 or der[0] != 0x30:
        raise PackageError("openssl returned no DER signature")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise PackageError("openssl returned no DER integer")
        n = der[i + 1]
        value = der[i + 2:i + 2 + n].lstrip(b"\x00")
        if len(value) > 32:
            raise PackageError("signature integer too long for P-256")
        out += value.rjust(32, b"\x00")
        i += 2 + n
    return out


def _env(*names: str) -> str:
    for name in names:
        value = (os.environ.get(name) or "").strip()
        if value:
            return value
    return ""


def asc_token(now: int | None = None) -> str:
    key_id = _env("ASC_API_KEY_ID", "ASC_KEY_ID")
    issuer = _env("ASC_API_ISSUER_ID", "ASC_ISSUER_ID")
    key_path = _env("ASC_API_KEY_PATH", "ASC_PRIVATE_KEY_PATH")
    key_b64 = _env("ASC_API_KEY_P8_BASE64")
    if not key_id or not issuer or not (key_path or key_b64):
        raise PackageError("App Store Connect key missing: set ASC_API_KEY_ID, ASC_API_ISSUER_ID and ASC_API_KEY_PATH or ASC_API_KEY_P8_BASE64")
    now = int(now if now is not None else time.time())
    header = _b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    claims = _b64url(json.dumps({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                                separators=(",", ":")).encode())
    signing_input = f"{header}.{claims}".encode()
    with tempfile.TemporaryDirectory() as tmp:
        if not key_path:
            key_path = os.path.join(tmp, "key.p8")
            fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as handle:
                handle.write(base64.b64decode(key_b64))
        signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing_input,
                                capture_output=True, check=False)
    if signed.returncode != 0:
        raise PackageError("openssl could not sign the App Store Connect token")
    return f"{header}.{claims}.{_b64url(_der_to_raw(signed.stdout))}"


def _asc_error_code(body: Any) -> str:
    errors = body.get("errors") if isinstance(body, dict) else None
    if isinstance(errors, list) and errors and isinstance(errors[0], dict):
        return str(errors[0].get("code") or "unknown")
    return "unknown"


# --- API -------------------------------------------------------------------


def api_base() -> str:
    override = os.environ.get("CMUX_ASC_API_BASE_URL")
    if not override:
        return OFFICIAL_API_BASE
    host = urllib.parse.urlsplit(override).hostname
    if host not in {"127.0.0.1", "::1", "localhost"}:
        raise PackageError("CMUX_ASC_API_BASE_URL is restricted to loopback tests")
    return override.rstrip("/")


class Api:
    def __init__(self, token: str | None = None) -> None:
        self._token = token
        self.base = api_base()
        self.timeout = int(os.environ.get("ASC_TIMEOUT_SECONDS", "60"))

    def token(self) -> str:
        if self._token is None:
            self._token = os.environ.get("CMUX_ASC_TEST_TOKEN") if self.base != OFFICIAL_API_BASE else None
            if not self._token:
                self._token = asc_token()
        return self._token

    def request(self, method: str, path: str, body: Any = None) -> Any:
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token())
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            try:
                code = _asc_error_code(json.loads(error.read() or b"{}"))
            except ValueError:
                code = "unknown"
            # Only the status and Apple's scalar code: error bodies can echo detail.
            raise PackageError(f"{method} {path.split('?')[0]} -> HTTP {error.code} ({code})") from None

    def get(self, path: str) -> Any:
        return self.request("GET", path)

    def get_all(self, path: str) -> list[dict]:
        items: list[dict] = []
        url = path
        for _ in range(50):
            body = self.get(url)
            items.extend(body.get("data") or [])
            nxt = (body.get("links") or {}).get("next")
            if not nxt:
                return items
            parts = urllib.parse.urlsplit(nxt)
            url = parts.path + ("?" + parts.query if parts.query else "")
        raise PackageError(f"too many pages at {path.split('?')[0]}")


def version_id(api: Api, app: str, version: str) -> str:
    query = urllib.parse.urlencode({"filter[versionString]": version, "filter[platform]": "IOS", "limit": "5"})
    data = api.get(f"/v1/apps/{app}/appStoreVersions?{query}").get("data") or []
    if not data:
        raise PackageError(f"App Store version {version} not found for app {app}")
    return data[0]["id"]


# --- sync-notes --------------------------------------------------------------


def render_notes(template: str, detail: dict, env: dict[str, str] | None = None) -> str:
    env = os.environ if env is None else env
    template = TEMPLATE_COMMENT.sub("", template)
    demo = (detail.get("demoAccountName") or "").strip()
    inbox = ""
    if demo.lower().endswith("@mailinator.com"):
        # The current demo account decides its inbox; notes from an earlier
        # account must never send the reviewer to the old one.
        local = demo.split("@", 1)[0]
        inbox = "https://www.mailinator.com/v4/public/inboxes.jsp?" + urllib.parse.urlencode({"to": local})
    else:
        match = MAILINATOR_URL.search(detail.get("notes") or "")
        if match:
            inbox = match.group(0).rstrip(".,")
    values = {
        "DEMO_ACCOUNT_EMAIL": demo,
        "MAILINATOR_PUBLIC_INBOX_URL": inbox,
        "REVIEW_CONTACT_EMAIL": (detail.get("contactEmail") or "").strip(),
        "REVIEW_CONTACT_PHONE": (detail.get("contactPhone") or "").strip(),
    }
    for name, variable in REVIEW_ENV_VALUES.items():
        values[name] = (env.get(variable) or "").strip()
    used = set(PLACEHOLDER.findall(template))
    unknown = sorted(used - set(values))
    if unknown:
        raise PackageError(f"{', '.join(unknown)}: no source for these placeholders in the notes template")
    missing = sorted(name for name in used if not values[name])
    if missing:
        where = [
            f"{name} (set {REVIEW_ENV_VALUES[name]})" if name in REVIEW_ENV_VALUES
            else f"{name} (fill it in App Store Connect App Review Information)"
            for name in missing
        ]
        raise PackageError("App Review notes are not written while these are empty: " + ", ".join(where))
    notes = PLACEHOLDER.sub(lambda m: values[m.group(1)], template).strip() + "\n"
    if len(notes) > NOTES_LIMIT:
        raise PackageError(f"rendered notes are {len(notes)} characters; App Store Connect allows {NOTES_LIMIT}")
    return notes


def sync_notes(api: Api, app: str, version: str, template_path: Path, dry_run: bool) -> bool:
    vid = version_id(api, app, version)
    body = api.get(f"/v1/appStoreVersions/{vid}/appStoreReviewDetail")
    data = body.get("data")
    if not data:
        raise PackageError(f"version {version} has no App Review Information; fill it in App Store Connect")
    detail = data.get("attributes") or {}
    notes = render_notes(template_path.read_text(encoding="utf-8"), detail)
    if (detail.get("notes") or "").strip() == notes.strip():
        note("App Review notes already match the repository")
        return False
    if dry_run:
        note("App Review notes differ from the repository (dry run, not written)")
        return True
    api.request("PATCH", f"/v1/appStoreReviewDetails/{data['id']}", {
        "data": {"type": "appStoreReviewDetails", "id": data["id"], "attributes": {"notes": notes}},
    })
    note(f"App Review notes for {version} written from {template_path.name}")
    return True


# --- sync-listing ------------------------------------------------------------


def version_listing(version: str, metadata_dir: Path = VERSION_METADATA_DIR) -> dict:
    """The en-US listing in git: its supportUrl applies to every locale."""
    path = metadata_dir / version / "en-US.json"
    try:
        listing = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise PackageError(f"{path}: cannot read the listing ({error})") from None
    url = (listing.get("supportUrl") or "").strip()
    if not url.startswith("https://"):
        raise PackageError(f"{path}: supportUrl must be an https URL, got {url!r}")
    return listing


def sync_listing(api: Api, app: str, version: str, listing: dict, dry_run: bool) -> list[str]:
    support_url = listing["supportUrl"].strip()
    vid = version_id(api, app, version)
    path = f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations?limit=50"
    localizations = api.get_all(path)
    if not localizations:
        raise PackageError(f"version {version} has no localizations")
    for item in localizations:
        attrs = item.get("attributes") or {}
        locale = attrs.get("locale") or item["id"]
        if (attrs.get("supportUrl") or "").strip() == support_url:
            continue
        if dry_run:
            note(f"{locale}: supportUrl differs from the repository (dry run, not written)")
            continue
        api.request("PATCH", f"/v1/appStoreVersionLocalizations/{item['id']}", {
            "data": {"type": "appStoreVersionLocalizations", "id": item["id"], "attributes": {"supportUrl": support_url}},
        })
        note(f"{locale}: supportUrl written from the repository")
    # Read back after a write too: a write that did not take fails here.
    current = localizations if dry_run else api.get_all(path)
    wrong = []
    for item in current:
        attrs = item.get("attributes") or {}
        if (attrs.get("supportUrl") or "").strip() != support_url:
            wrong.append(f"{attrs.get('locale') or item['id']} supportUrl is {attrs.get('supportUrl')!r}, not {support_url}")
    for line in wrong:
        note("BLOCKING: " + line)
    if not wrong:
        note(f"all {len(current)} locale(s) of {version} use Support URL {support_url}")
    return wrong


# --- CLI ---------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", default=os.environ.get("ASC_APP_ID", ""))
    sub = parser.add_subparsers(dest="command", required=True)
    notes_p = sub.add_parser("sync-notes")
    notes_p.add_argument("--version", help="App Store version (default: MARKETING_VERSION in project.yml)")
    notes_p.add_argument("--template", type=Path, default=DEFAULT_NOTES_TEMPLATE)
    notes_p.add_argument("--dry-run", action="store_true")
    support_p = sub.add_parser("sync-listing")
    support_p.add_argument("--version", help="App Store version (default: MARKETING_VERSION in project.yml)")
    support_p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if not re.fullmatch(r"[0-9]+", args.app or ""):
        parser.error("--app must be the numeric App Store Connect app id")
    try:
        version = args.version or marketing_version()
        api = Api()
        if args.command == "sync-notes":
            sync_notes(api, args.app, version, args.template, args.dry_run)
            return 0
        if args.command == "sync-listing":
            listing = version_listing(version)
            return 1 if sync_listing(api, args.app, version, listing, args.dry_run) else 0
    except PackageError as error:
        note(f"error: {error}")
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main())
