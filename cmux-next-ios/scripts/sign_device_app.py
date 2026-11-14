#!/usr/bin/env python3
"""Sign the fleet's unsigned cmux-next iPhone app on this Mac, for the phones it installs on.

  sign_device_app.py --app CmuxMobileApp.app --checkout DIR --team 7WLXT3NR37 --device UDID [--device UDID ...]

The fleet (scripts/ci/cmux-next-ios-sim.sh handoff) builds the device app with
CODE_SIGNING_ALLOWED=NO, so it carries no signature and no entitlements. This signs it in place
with this Mac's Apple Development identity and a development provisioning profile already on
this Mac (Xcode's or a hand-installed one) that names the app (or the team wildcard) and every
target phone, and whose certificate is in the keychain. Nothing is fetched or registered: a phone
no profile names is reported, never added to the team.

Each bundle's entitlements are its target's own file from the checkout (the exact commit the app
was built from: project.yml's device choice, no App Group), with Xcode's build variables put in,
plus the development keys Xcode adds (application-identifier, team-identifier, get-task-allow).
Every keychain group must be one the profile allows. Frameworks are signed first, then the
extensions, then the app; `codesign --verify --deep --strict` must pass.

Prints one JSON line: {"identity": "<sha1>", "profile": "<name>", "uuid": "...", "devices": [...]}.
Exit 1 with the reason on stderr when no profile or identity fits.
Its tests: python3 cmux-next-ios/scripts/test_sign_device_app.py
"""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile

# Each bundle in the app (by its directory name) and the entitlements file its target signs with on a
# device (project.yml: CMUX_MOBILE_APP_GROUP is NO for device builds, so the Keychain variant).
ENTITLEMENTS = {
    "CmuxMobileApp.app": "cmux-next-ios/App/CmuxMobileApp-Keychain.entitlements",
    "CmuxMobileNotificationContent.appex": "cmux-next-ios/NotificationContent/NotificationContent.entitlements",
    "CmuxMobileNotificationService.appex": "cmux-next-ios/NotificationService/NotificationService.entitlements",
}
PROFILE_DIRS = ("~/Library/Developer/Xcode/UserData/Provisioning Profiles", "~/Library/MobileDevice/Provisioning Profiles")


class SignError(Exception):
    pass


def profile_fits(profile, team, bundle_id, devices, identities, now):
    """Why PROFILE (a decoded provisioning profile dict) cannot sign BUNDLE_ID for DEVICES, or None when it can.
    IDENTITIES: the SHA-1s (upper hex) of this keychain's signing identities."""
    ents = profile.get("Entitlements") or {}
    app_id = ents.get("application-identifier", "")
    if app_id not in (f"{team}.{bundle_id}", f"{team}.*"):
        return f"names {app_id or 'no app'}"
    if ents.get("get-task-allow") is not True:
        return "is not a development profile"
    expires = profile.get("ExpirationDate")
    if isinstance(expires, datetime.datetime):
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=datetime.timezone.utc)
        if expires <= now:
            return "expired"
    provisioned = {str(d).upper() for d in profile.get("ProvisionedDevices") or []}
    missing = [d for d in devices if d.upper() not in provisioned]
    if missing:
        return "does not name " + ", ".join(missing)
    if not certificate(profile, identities):
        return "has no certificate in this keychain"
    return None


def certificate(profile, identities):
    """The SHA-1 of the first profile certificate this keychain can sign with, else None."""
    for cert in profile.get("DeveloperCertificates") or []:
        digest = hashlib.sha1(bytes(cert)).hexdigest().upper()
        if digest in identities:
            return digest
    return None


def choose_profile(profiles, team, bundle_id, devices, identities, now):
    """The best fitting (path, profile): an exact app id beats the team wildcard, then the latest expiry.
    Raises SignError naming why each one did not fit."""
    fits, why = [], []
    for path, profile in profiles:
        reason = profile_fits(profile, team, bundle_id, devices, identities, now)
        if reason is None:
            fits.append((path, profile))
        else:
            why.append(f"{profile.get('Name') or os.path.basename(path)}: {reason}")
    if not fits:
        raise SignError("no development profile on this Mac fits " + bundle_id + " for " + ", ".join(devices)
                        + (" (" + "; ".join(why[:8]) + ")" if why else " (no profiles found)")
                        + ". Install one that names the phone (Xcode > Settings > Accounts, or the team's"
                          " development profile), then rerun")

    def rank(item):
        ents = item[1].get("Entitlements") or {}
        exact = ents.get("application-identifier") == f"{team}.{bundle_id}"
        expires = item[1].get("ExpirationDate") or datetime.datetime.min
        if isinstance(expires, datetime.datetime) and expires.tzinfo is not None:
            expires = expires.replace(tzinfo=None)
        return (exact, expires)
    return max(fits, key=rank)


def entitlements(source_text, team, bundle_id, app_bundle_id):
    """A bundle's signing entitlements from its target's .entitlements text (Xcode's variables put in)."""
    text = (source_text.replace("$(AppIdentifierPrefix)", team + ".")
            .replace("$(DEVELOPMENT_TEAM)", team)
            .replace("$(PRODUCT_BUNDLE_IDENTIFIER)", bundle_id)
            .replace("$(CMUX_MOBILE_APP_BUNDLE_ID)", app_bundle_id))
    if "$(" in text:
        raise SignError("an entitlement has a build variable this signer does not know: "
                        + re.search(r"\$\([^)]*\)", text).group(0))
    ents = plistlib.loads(text.encode())
    ents.pop("com.apple.security.application-groups", None)  # device builds carry no App Group
    ents["application-identifier"] = f"{team}.{bundle_id}"
    ents["com.apple.developer.team-identifier"] = team
    ents["get-task-allow"] = True
    return ents


def allowed(ents, profile):
    """Why the profile does not allow ENTS, or None."""
    granted = (profile.get("Entitlements") or {}).get("keychain-access-groups") or []
    for group in ents.get("keychain-access-groups") or []:
        if not any(group == g or (g.endswith(".*") and group.startswith(g[:-1])) for g in granted):
            return f"keychain group {group} is not in the profile"
    for key in ents:
        if key not in ("application-identifier", "com.apple.developer.team-identifier", "get-task-allow",
                       "keychain-access-groups"):
            if key not in (profile.get("Entitlements") or {}):
                return f"entitlement {key} is not in the profile"
    return None


def bundles(app):
    """(path, directory name) of every bundle to sign, innermost first: extensions, then the app."""
    plugins = os.path.join(app, "PlugIns")
    out = []
    if os.path.isdir(plugins):
        for name in sorted(os.listdir(plugins)):
            if name.endswith(".appex"):
                out.append((os.path.join(plugins, name), name))
    out.append((app, os.path.basename(app)))
    return out


def load_profiles(dirs):
    out = []
    for d in dirs:
        d = os.path.expanduser(d)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if not name.endswith(".mobileprovision"):
                continue
            path = os.path.join(d, name)
            decoded = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True)
            if decoded.returncode == 0:
                try:
                    out.append((path, plistlib.loads(decoded.stdout)))
                except Exception:  # noqa: BLE001 - an unreadable profile is skipped, never fatal
                    continue
    return out


def identities():
    out = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
    return {m.group(1).upper() for m in re.finditer(r"\b([0-9A-Fa-f]{40})\b", out)}


def codesign(identity, path, ents=None, workdir=None):
    args = ["codesign", "--force", "--sign", identity, "--timestamp=none", "--generate-entitlement-der"]
    if ents is not None:
        file = os.path.join(workdir, hashlib.sha1(path.encode()).hexdigest() + ".entitlements")
        with open(file, "wb") as f:
            plistlib.dump(ents, f)
        args += ["--entitlements", file]
    result = subprocess.run(args + [path], capture_output=True, text=True)
    if result.returncode != 0:
        raise SignError(f"codesign {os.path.basename(path)} failed: {result.stderr.strip()[-400:]}")


def sign(a):
    info = plistlib.load(open(os.path.join(a.app, "Info.plist"), "rb"))
    app_bundle_id = info.get("CFBundleIdentifier", "")
    if not re.fullmatch(r"dev\.cmux\.mobile\.[a-z0-9][a-z0-9-]*", app_bundle_id):
        raise SignError(f"{app_bundle_id or 'no bundle id'} is not a cmux-next dev build (dev.cmux.mobile.<tag>)")
    if info.get("CmuxMobileKeychainGroup") != f"{a.team}.{app_bundle_id}.push":
        raise SignError(f"Info.plist CmuxMobileKeychainGroup is {info.get('CmuxMobileKeychainGroup')!r}, "
                        f"not {a.team}.{app_bundle_id}.push (built without DEVELOPMENT_TEAM={a.team})")
    found = identities()
    if not found:
        raise SignError("no code signing identity in this keychain (an Apple Development certificate of team " + a.team + ")")
    path, profile = choose_profile(load_profiles(PROFILE_DIRS), a.team, app_bundle_id, a.device, found,
                                   datetime.datetime.now(datetime.timezone.utc))
    identity = certificate(profile, found)
    plan = []
    for bundle, name in bundles(a.app):
        if name not in ENTITLEMENTS:
            raise SignError(f"{name} has no entitlements mapping in sign_device_app.py; add its target's file")
        bundle_id = plistlib.load(open(os.path.join(bundle, "Info.plist"), "rb")).get("CFBundleIdentifier", "")
        if bundle != a.app and not bundle_id.startswith(app_bundle_id + "."):
            raise SignError(f"{name} is {bundle_id}, not under {app_bundle_id}")
        source = open(os.path.join(a.checkout, ENTITLEMENTS[name]), encoding="utf-8").read()
        ents = entitlements(source, a.team, bundle_id, app_bundle_id)
        reason = allowed(ents, profile)
        if reason:
            raise SignError(f"{name}: {reason} ({profile.get('Name')})")
        plan.append((bundle, ents))
    with tempfile.TemporaryDirectory() as work:
        for bundle, ents in plan:
            frameworks = os.path.join(bundle, "Frameworks")
            if os.path.isdir(frameworks):
                for name in sorted(os.listdir(frameworks)):
                    if name.endswith((".framework", ".dylib")):
                        codesign(identity, os.path.join(frameworks, name))
            with open(path, "rb") as src, open(os.path.join(bundle, "embedded.mobileprovision"), "wb") as dst:
                dst.write(src.read())
            codesign(identity, bundle, ents, work)
    check = subprocess.run(["codesign", "--verify", "--deep", "--strict", a.app], capture_output=True, text=True)
    if check.returncode != 0:
        raise SignError("the signed app does not verify: " + check.stderr.strip()[-400:])
    print(json.dumps({"identity": identity, "profile": profile.get("Name"), "uuid": profile.get("UUID"),
                      "devices": a.device, "bundle_id": app_bundle_id}))


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", required=True)
    p.add_argument("--checkout", required=True)
    p.add_argument("--team", default="7WLXT3NR37")
    p.add_argument("--device", action="append", required=True)
    a = p.parse_args(argv)
    try:
        sign(a)
    except (SignError, OSError) as error:
        print(f"sign_device_app: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
