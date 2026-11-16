#!/usr/bin/env python3
"""Make the App Store Connect signing setup of cmux-next-ios exist, then hand
out its App Store profiles: the "ensure" step of .github/workflows/ios-app-store.yml.

For the app's bundle id and its two notification extensions
(<bundle id>.notification-content, <bundle id>.notification-service), through the
public App Store Connect API with the release environment's key:

  1. the bundle id is registered (iOS), or registered now;
  2. the app's capabilities are on: Push Notifications and Sign in with Apple
     (the extensions need none; their Keychain group is the team's own);
  3. an ACTIVE IOS_APP_STORE profile with the given name exists for it and
     lists the distribution certificate CI signs with (named by its SHA-1); a
     profile of that name that is invalid (a capability changed) or lists other
     certificates is deleted and made again. Only profiles with these names are
     ever deleted: they are this step's own;
  4. each profile is written to --out-dir as app.mobileprovision,
     content.mobileprovision and service.mobileprovision.

Every step reads first and changes only what is missing, so a second run
changes nothing. What the API cannot do (App Groups, the APNs key, the App
Store Connect record itself, the key's own role) stays a person's job in the
Developer portal or App Store Connect.

Credentials: ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH (or ASC_API_KEY_ID,
ASC_API_ISSUER_ID and ASC_API_KEY_PATH). The token is minted with `openssl`
(no third-party Python in a job that holds the key), and no response body is
ever printed: errors show the status and Apple's error code only.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

OFFICIAL_API_BASE = "https://api.appstoreconnect.apple.com"
APP_STORE = "IOS_APP_STORE"
DISTRIBUTION_TYPES = ("DISTRIBUTION", "IOS_DISTRIBUTION")
# The app's capabilities, with the settings App Store Connect needs for each.
APP_CAPABILITIES: dict[str, list[dict[str, Any]] | None] = {
    "PUSH_NOTIFICATIONS": None,
    "APPLE_ID_AUTH": [
        {"key": "APPLE_ID_AUTH_APP_CONSENT", "options": [{"key": "PRIMARY_APP_CONSENT"}]},
    ],
}


class EnsureError(RuntimeError):
    pass


def note(message: str) -> None:
    print(f"asc-ensure-signing: {message}", file=sys.stderr)


# --- Token ------------------------------------------------------------------


def _b64u(raw: bytes) -> bytes:
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def _der_to_raw(der: bytes) -> bytes:
    """A DER ECDSA signature (openssl) as the 64-byte r||s ES256 wants."""
    if len(der) < 8 or der[0] != 0x30:
        raise EnsureError("malformed ECDSA signature from openssl")
    idx = 2 if not der[1] & 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[idx] != 0x02:
            raise EnsureError("malformed ECDSA signature from openssl")
        length = der[idx + 1]
        value = der[idx + 2 : idx + 2 + length].lstrip(b"\x00")
        if len(value) > 32:
            raise EnsureError("malformed ECDSA signature from openssl")
        out += value.rjust(32, b"\x00")
        idx += 2 + length
    return out


def mint_token() -> str:
    key_id = os.environ.get("ASC_KEY_ID") or os.environ.get("ASC_API_KEY_ID")
    issuer = os.environ.get("ASC_ISSUER_ID") or os.environ.get("ASC_API_ISSUER_ID")
    key_path = os.environ.get("ASC_PRIVATE_KEY_PATH") or os.environ.get("ASC_API_KEY_PATH")
    if not key_id or not issuer or not key_path or not Path(key_path).is_file():
        raise EnsureError("set ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY_PATH (a .p8 file)")
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    now = int(time.time())
    payload = {"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    signing_input = _b64u(json.dumps(header).encode()) + b"." + _b64u(json.dumps(payload).encode())
    proc = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise EnsureError("openssl could not sign the token")
    return (signing_input + b"." + _b64u(_der_to_raw(proc.stdout))).decode()


# --- API ----------------------------------------------------------------------


def api_base() -> str:
    override = os.environ.get("CMUX_ASC_API_BASE_URL")
    if not override:
        return OFFICIAL_API_BASE
    if urllib.parse.urlsplit(override).hostname not in {"127.0.0.1", "::1", "localhost"}:
        raise EnsureError("CMUX_ASC_API_BASE_URL is restricted to loopback tests")
    return override.rstrip("/")


class Api:
    def __init__(self) -> None:
        self.base = api_base()
        self.timeout = int(os.environ.get("ASC_TIMEOUT_SECONDS", "60"))
        self._token: str | None = None

    def token(self) -> str:
        if self._token is None:
            test_token = os.environ.get("CMUX_ASC_TEST_TOKEN") if self.base != OFFICIAL_API_BASE else None
            self._token = test_token or mint_token()
        return self._token

    def request(self, method: str, path: str, body: Any = None) -> Any:
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token())
        req.add_header("Content-Type", "application/json")
        for attempt in range(4):
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                    raw = resp.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as error:
                code = "unknown"
                try:
                    errors = json.loads(error.read() or b"{}").get("errors") or [{}]
                    code = str(errors[0].get("code") or "unknown")
                except (ValueError, AttributeError, IndexError):
                    pass
                if error.code >= 500 and attempt < 3:
                    time.sleep(2**attempt)
                    continue
                hint = " (the key needs the Admin or App Manager role with access to Certificates, Identifiers & Profiles)" if error.code in (401, 403) else ""
                raise EnsureError(f"{method} {path.split('?')[0]} -> HTTP {error.code} ({code}){hint}") from None
            except urllib.error.URLError as error:
                if attempt < 3:
                    time.sleep(2**attempt)
                    continue
                raise EnsureError(f"{method} {path.split('?')[0]} -> {error.reason}") from None
        raise EnsureError(f"{method} {path.split('?')[0]} did not answer")

    def get_all(self, path: str) -> list[dict]:
        items: list[dict] = []
        url = path
        for _ in range(50):
            body = self.request("GET", url)
            items.extend(body.get("data") or [])
            nxt = (body.get("links") or {}).get("next")
            if not nxt:
                return items
            parts = urllib.parse.urlsplit(nxt)
            url = parts.path + ("?" + parts.query if parts.query else "")
        raise EnsureError(f"too many pages at {path.split('?')[0]}")


def q(params: dict[str, str]) -> str:
    return urllib.parse.urlencode(params, safe="[],")


# --- Steps ----------------------------------------------------------------------


def ensure_bundle_id(api: Api, identifier: str, name: str, changes: list[str]) -> str:
    found = api.get_all("/v1/bundleIds?" + q({"filter[identifier]": identifier, "limit": "200"}))
    exact = [b for b in found if (b.get("attributes") or {}).get("identifier") == identifier]
    if exact:
        platform = (exact[0].get("attributes") or {}).get("platform")
        if platform not in ("IOS", "UNIVERSAL"):
            raise EnsureError(f"bundle id {identifier} is registered for {platform}, not iOS")
        return str(exact[0]["id"])
    created = api.request(
        "POST",
        "/v1/bundleIds",
        {"data": {"type": "bundleIds", "attributes": {"identifier": identifier, "name": name, "platform": "IOS"}}},
    )
    changes.append(f"registered bundle id {identifier}")
    return str(created["data"]["id"])


def ensure_capabilities(api: Api, bundle_pk: str, identifier: str, wanted: dict[str, Any], changes: list[str]) -> bool:
    if not wanted:
        return False
    have = {
        (c.get("attributes") or {}).get("capabilityType")
        for c in api.get_all(f"/v1/bundleIds/{bundle_pk}/bundleIdCapabilities?limit=200")
    }
    changed = False
    for capability, settings in wanted.items():
        if capability in have:
            continue
        attributes: dict[str, Any] = {"capabilityType": capability}
        if settings:
            attributes["settings"] = settings
        api.request(
            "POST",
            "/v1/bundleIdCapabilities",
            {
                "data": {
                    "type": "bundleIdCapabilities",
                    "attributes": attributes,
                    "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_pk}}},
                }
            },
        )
        changes.append(f"enabled {capability} on {identifier}")
        changed = True
    return changed


def certificate_id(api: Api, sha1: str) -> str:
    want = sha1.replace(":", "").strip().upper()
    certificates = api.get_all(
        "/v1/certificates?" + q({"filter[certificateType]": ",".join(DISTRIBUTION_TYPES), "limit": "200"})
    )
    for cert in certificates:
        content = (cert.get("attributes") or {}).get("certificateContent") or ""
        try:
            digest = hashlib.sha1(base64.b64decode(content)).hexdigest().upper()
        except ValueError:
            continue
        if digest == want:
            return str(cert["id"])
    raise EnsureError(
        f"no distribution certificate with SHA-1 {want} in App Store Connect: the release environment's "
        "IOS_DISTRIBUTION_CERTIFICATE_BASE64 is not one of the team's distribution certificates"
    )


def ensure_profile(
    api: Api, bundle_pk: str, identifier: str, name: str, cert_pk: str, changes: list[str], *, stale: bool = False
) -> bytes:
    """The profile's content. `stale`: a capability changed this run, so a profile
    made before it lacks the new entitlement even if it still reads ACTIVE."""
    profiles = [
        p
        for p in api.get_all(f"/v1/bundleIds/{bundle_pk}/profiles?limit=200")
        if (p.get("attributes") or {}).get("name") == name
    ]
    for profile in profiles:
        attributes = profile.get("attributes") or {}
        usable = not stale and attributes.get("profileType") == APP_STORE and attributes.get("profileState") == "ACTIVE"
        if usable:
            certs = {str(c.get("id")) for c in api.get_all(f"/v1/profiles/{profile['id']}/certificates?limit=200")}
            usable = cert_pk in certs
        if usable and attributes.get("profileContent"):
            return base64.b64decode(attributes["profileContent"])
        api.request("DELETE", f"/v1/profiles/{profile['id']}")
        changes.append(f"deleted stale profile \"{name}\" ({attributes.get('profileState')})")
    created = api.request(
        "POST",
        "/v1/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {"name": name, "profileType": APP_STORE},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_pk}},
                    "certificates": {"data": [{"type": "certificates", "id": cert_pk}]},
                },
            }
        },
    )
    changes.append(f"created profile \"{name}\" for {identifier}")
    content = (created["data"].get("attributes") or {}).get("profileContent")
    if not content:
        raise EnsureError(f"App Store Connect returned profile \"{name}\" without its content")
    return base64.b64decode(content)


def run(args: argparse.Namespace) -> list[str]:
    api = Api()
    changes: list[str] = []
    cert_pk = certificate_id(api, args.certificate_sha1)
    targets = [
        ("app", args.bundle_id, args.bundle_name, args.app_profile, APP_CAPABILITIES),
        ("content", f"{args.bundle_id}.notification-content", f"{args.bundle_name} Notification Content", args.content_profile, {}),
        ("service", f"{args.bundle_id}.notification-service", f"{args.bundle_name} Notification Service", args.service_profile, {}),
    ]
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    os.chmod(out, 0o700)
    for role, identifier, bundle_name, profile_name, capabilities in targets:
        bundle_pk = ensure_bundle_id(api, identifier, bundle_name, changes)
        changed = ensure_capabilities(api, bundle_pk, identifier, capabilities, changes)
        content = ensure_profile(api, bundle_pk, identifier, profile_name, cert_pk, changes, stale=changed)
        path = out / f"{role}.mobileprovision"
        path.write_bytes(content)
        os.chmod(path, 0o600)
        note(f"{identifier}: profile \"{profile_name}\" -> {path}")
    return changes


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--bundle-name", default="cmux", help="the portal name for new bundle ids (letters, digits, spaces)")
    parser.add_argument("--app-profile", required=True)
    parser.add_argument("--content-profile", required=True)
    parser.add_argument("--service-profile", required=True)
    parser.add_argument("--certificate-sha1", required=True, help="SHA-1 of the distribution certificate CI signs with")
    parser.add_argument("--out-dir", required=True)
    args = parser.parse_args(argv)
    try:
        changes = run(args)
    except EnsureError as error:
        print(f"asc-ensure-signing: error: {error}", file=sys.stderr)
        return 1
    if changes:
        for change in changes:
            note(change)
    else:
        note("nothing to change")
    return 0


if __name__ == "__main__":
    sys.exit(main())
