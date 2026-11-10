#!/usr/bin/env python3
"""App Review before Apple: one ranked list of everything that would get the
cmux NEXT iOS app (cmux-next-ios, CmuxMobileApp) rejected, from what a machine
can check.

Two subcommands:

  lint    Static guideline checks on the metadata, the cmux-next-ios source
          tree, and (when given) the exact .app or .ipa to be submitted:
          Info.plist purpose strings (from project.yml, which xcodegen turns
          into the plist), entitlements, extensions, binary symbols, external
          purchase links, account deletion, Sign in with Apple in the shipping
          configuration, App Store Connect processing rules
          (scripts/cmux-next/check-app-store-rules.py), URLs (with
          --check-urls), and the rejection-history coverage check (every past
          rejection names a detector that still exists).

  report  Merge lint JSON, xcresult test outcomes and `asc validate` JSON into
          one ranked Markdown list (blocking first). Exit 1 when anything
          blocks. This is the list nothing is submitted past.

The NEXT app sells nothing (no StoreKit), so there are no plan, subscription or
restore rules; an outside purchase link is still a 3.1.1 rejection, so that one
stays.

Standard library only; runs on Linux (metadata, source, URLs, plist and
Mach-O string scans) and macOS (adds codesign/otool when present).

Usage:
  cmux-next-ios/scripts/app_review_gate.py lint --source-root . --lane appstore \
      [--app path/CmuxMobileApp.app | --ipa path/CmuxMobileApp.ipa] [--check-urls] [--json out.json]
  cmux-next-ios/scripts/app_review_gate.py report --lint lint.json \
      [--xcresult-json tests.json ...] [--asc-validate asc.json] [--out report.md]
  cmux-next-ios/scripts/app_review_gate.py version --source-root .   # the version asc validates
"""

from __future__ import annotations

import argparse
import dataclasses
import html
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from typing import Iterable

SEVERITY_ORDER = {"blocker": 0, "warning": 1, "info": 2}

# The NEXT app: cmux-next-ios/project.yml (xcodegen) builds CmuxMobileApp from
# App/ and CmuxMobileKit, its two notification extensions, and the
# Packages/iOS/CmuxConversation package the kit depends on. The classic app
# (ios/cmux, Packages/iOS's other packages) is not judged here.
APP_DIR = "cmux-next-ios"
PROJECT_YML = "cmux-next-ios/project.yml"
IOS_SOURCE_DIRS = (
    "cmux-next-ios/App",
    "cmux-next-ios/CmuxMobileKit/Sources",
    "cmux-next-ios/NotificationContent",
    "cmux-next-ios/NotificationService",
    "Packages/iOS/CmuxConversation/Sources",
)
LOCALIZABLE_GLOB = "cmux-next-ios/CmuxMobileKit/Sources/*/Resources/Localizable.xcstrings"
# The NEXT app's App Store review package (metadata, screenshots, reviewer
# notes) and the rejection history live beside the app.
REVIEW_DIR = "cmux-next-ios/AppStoreReview"
METADATA_DIR = "cmux-next-ios/AppStoreReview/metadata"
SCREENSHOTS_DIR = "cmux-next-ios/AppStoreReview/screenshots/en-US"
HISTORY_FILE = "cmux-next-ios/AppStoreReview/rejection-history.json"
# The public App Store build: project.yml's AppStore configuration, bundle
# com.cmux.app (the record the classic app used; NEXT replaces it as an update).
APPSTORE_CONFIG = "AppStore"
APPSTORE_BUNDLE_ID = "com.cmux.app"
# The App Store distribution configurations (AppStore, TestFlight,
# TestFlightStaging) sign with these; project.yml says so.
APPSTORE_ENTITLEMENTS = (
    "cmux-next-ios/App/CmuxMobileApp-TestFlight.entitlements",
    "cmux-next-ios/App/CmuxMobileApp-TestFlight-Group.entitlements",
)
UITEST_DIR = "cmux-next-ios/UITests"
STORE_RULES = "scripts/cmux-next/check-app-store-rules.py"


@dataclasses.dataclass
class Finding:
    rule: str
    guideline: str
    severity: str  # blocker | warning | info
    message: str
    where: str = ""

    def as_dict(self) -> dict:
        return dataclasses.asdict(self)


class Lint:
    def __init__(self, root: Path, lane: str) -> None:
        self.root = root
        self.lane = lane
        self.findings: list[Finding] = []
        self.checked: list[str] = []
        self._texts: dict[Path, str] | None = None

    def texts(self) -> dict[Path, str]:
        if self._texts is None:
            self._texts = {}
            for path in self.swift_files():
                try:
                    self._texts[path] = path.read_text(errors="ignore")
                except OSError:
                    continue
        return self._texts

    def add(self, rule: str, guideline: str, severity: str, message: str, where: str = "") -> None:
        self.findings.append(Finding(rule, guideline, severity, message, where))

    def ran(self, rule: str) -> None:
        self.checked.append(rule)

    # ------------------------------------------------------------------ files

    def swift_files(self) -> Iterable[Path]:
        for rel in IOS_SOURCE_DIRS:
            base = self.root / rel
            if not base.is_dir():
                continue
            for path in base.rglob("*.swift"):
                parts = set(path.parts)
                if "Tests" in parts or any(p.endswith("Tests") for p in path.parts) or path.name == "Package.swift":
                    continue
                if "Debug" in parts or "Previews" in parts:
                    continue
                # DEBUG-only mock content (MockAgentSession, ChiefMockBackend,
                # DemoDriver): compiled out of shipping builds, and
                # cmux-next-ios/scripts/check-production-binary.sh proves it on
                # the binary.
                stem = path.stem
                if stem.startswith("Mock") or stem.endswith("MockBackend") or stem in ("DemoDriver", "DemoDirector"):
                    continue
                yield path

    def rel(self, path: Path) -> str:
        try:
            return str(path.relative_to(self.root))
        except ValueError:
            return str(path)

    # --------------------------------------------------------------- metadata

    def metadata(self) -> dict[str, dict]:
        out: dict[str, dict] = {}
        base = self.root / METADATA_DIR
        for path in sorted(base.rglob("*.json")):
            try:
                out[self.rel(path)] = json.loads(path.read_text())
            except (OSError, json.JSONDecodeError) as exc:
                self.add("metadata.parse", "2.3", "blocker", f"metadata file does not parse: {exc}", self.rel(path))
        return out

    def check_metadata(self) -> list[tuple[str, str, str]]:
        """Returns (url, field, file) triples for the URL check."""
        self.ran("metadata")
        meta = self.metadata()
        urls: list[tuple[str, str, str]] = []
        if not meta:
            self.add("metadata.missing", "2.3", "blocker",
                     f"no App Store metadata JSON in {METADATA_DIR}: the NEXT app's store listing (name, description, "
                     "support and privacy URLs) is unjudged until it is in the repo", METADATA_DIR)
            return urls
        limits = {"name": 30, "subtitle": 30, "promotionalText": 170, "keywords": 100, "description": 4000}
        placeholder = re.compile(r"\b(TODO|TBD|FIXME|lorem ipsum|coming soon)\b|<[A-Z][A-Z0-9_]{2,}>", re.I)
        other_platforms = re.compile(r"\b(Android|Google Play|Windows Phone)\b")
        has_support = has_privacy = False
        for rel, body in meta.items():
            if not isinstance(body, dict):
                continue
            for key, value in body.items():
                if not isinstance(value, str):
                    continue
                if key in limits and len(value) > limits[key]:
                    self.add("metadata.length", "2.3.7", "blocker",
                             f"{key} is {len(value)} characters; App Store Connect allows {limits[key]}", rel)
                if placeholder.search(value):
                    self.add("metadata.placeholder", "2.1", "blocker",
                             f"{key} contains placeholder text: {placeholder.search(value).group(0)!r}", rel)
                if other_platforms.search(value):
                    self.add("metadata.other-platform", "2.3.10", "blocker",
                             f"{key} names another platform: {other_platforms.search(value).group(0)!r}", rel)
                if key.lower().endswith("url") and value:
                    urls.append((value, key, rel))
                for url in re.findall(r"https?://[^\s)\"']+", value):
                    if not key.lower().endswith("url"):
                        urls.append((url.rstrip(".,"), key, rel))
            has_support |= bool(body.get("supportUrl"))
            has_privacy |= bool(body.get("privacyPolicyUrl"))
        if not has_support:
            self.add("metadata.support-url", "1.5", "blocker", "no supportUrl in the version metadata", METADATA_DIR)
        if not has_privacy:
            self.add("metadata.privacy-url", "5.1.1", "blocker", "no privacyPolicyUrl in the app-info metadata", METADATA_DIR)
        for family in ("iphone", "ipad"):
            shots = self.root / SCREENSHOTS_DIR / family
            count = len([p for p in shots.glob("*") if p.suffix.lower() in (".png", ".jpg", ".jpeg")]) if shots.is_dir() else 0
            if count == 0:
                self.add("metadata.screenshots", "2.3.3", "blocker", f"no {family} screenshots", self.rel(shots))
        return urls

    # ---------------------------------------------------------------- sources

    def is_next_app(self) -> bool:
        return (self.root / PROJECT_YML).is_file()

    def check_next_app_present(self) -> bool:
        """The gate judges the NEXT app. A source without cmux-next-ios (the
        classic app's tree) is never a pass."""
        self.ran("next-app")
        if self.is_next_app():
            return True
        self.add("source.not-next", "2.1", "blocker",
                 f"this source has no {PROJECT_YML}: it is not the NEXT iOS app, so there is nothing here to judge "
                 "(pass the gate a feat-cmux-next commit)", APP_DIR)
        return False

    def check_appstore_config(self) -> None:
        """The appstore lane judges the public build: project.yml must define
        the AppStore configuration with bundle com.cmux.app."""
        self.ran("appstore-config")
        text = (self.root / PROJECT_YML).read_text(errors="ignore")
        block = config_block(text, APPSTORE_CONFIG)
        if not re.search(rf"^  {APPSTORE_CONFIG}:\s*release\b", text, re.M) or block is None:
            self.add("appstore.config-missing", "2.1", "blocker",
                     f"{PROJECT_YML} has no {APPSTORE_CONFIG} configuration, so there is no public App Store build "
                     f"(bundle {APPSTORE_BUNDLE_ID}) to judge", PROJECT_YML)
            return
        bundle = re.search(r"^\s*CMUX_MOBILE_APP_BUNDLE_ID:\s*\"?([\w.]+)", block, re.M)
        if not bundle or bundle.group(1) != APPSTORE_BUNDLE_ID:
            self.add("appstore.bundle-id", "2.1", "blocker",
                     f"the {APPSTORE_CONFIG} configuration's bundle is {bundle.group(1) if bundle else 'unset'!s}, "
                     f"not {APPSTORE_BUNDLE_ID}", PROJECT_YML)

    def check_sources(self) -> list[tuple[str, str, str]]:
        self.ran("sources")
        urls: list[tuple[str, str, str]] = []
        texts = self.texts()
        joined = "\n".join(texts.values())

        # 5.1.1(v): account deletion must be reachable in the app.
        if not re.search(r"settings\.deleteAccount|[Dd]elete [Aa]ccount", joined):
            self.add("account.deletion", "5.1.1(v)", "blocker",
                     "no in-app account deletion found in the cmux-next-ios sources", APP_DIR)

        # 4.8: a third-party sign-in requires Sign in with Apple (or an equivalent).
        third_party = re.search(r"\"Continue with (Google|GitHub)\"|signIn\(with: \.(google|github)\)", joined)
        apple = re.search(r"\"Continue with Apple\"|signInWithApple\(|ASAuthorizationAppleIDProvider", joined)
        if third_party and not apple:
            self.add("signin.apple", "4.8", "blocker",
                     "third-party sign-in is offered without Sign in with Apple", APP_DIR)
        if third_party:
            self.check_apple_sign_in_ships()

        # 3.1.1 / 3.1.3: no external purchase routes in the App Store build.
        external = re.compile(r"(checkout\.stripe\.com|billing\.stripe\.com|buy\.stripe\.com|js\.stripe\.com|cmux\.com/pricing|cmux\.com/billing|/api/billing/(checkout|portal))")
        for path, text in texts.items():
            for lineno, line in enumerate(text.splitlines(), 1):
                if external.search(line) and not line.lstrip().startswith("//"):
                    self.add("iap.external-purchase", "3.1.1", "blocker",
                             f"external purchase or billing route in an iOS source: {external.search(line).group(0)}",
                             f"{self.rel(path)}:{lineno}")

        # 2.5.2: no downloaded or interpreted executable code.
        exec_patterns = {
            r"\bdlopen\(": "dlopen",
            r"Bundle\(url:[^)]*\)\??\.load\(\)": "loading a bundle from a URL",
            r"\bNSClassFromString\([^\"]": "dynamic class lookup from a non-literal",
            r"evaluateScript\(": "JavaScriptCore evaluateScript",
        }
        for path, text in texts.items():
            for pattern, label in exec_patterns.items():
                for match in re.finditer(pattern, text):
                    lineno = text.count("\n", 0, match.start()) + 1
                    self.add("exec.dynamic-code", "2.5.2", "warning",
                             f"{label}: confirm it never runs code that was not in the reviewed binary",
                             f"{self.rel(path)}:{lineno}")

        # Private and system APIs that already cost us a rejection.
        vpn = re.compile(r"\b(NEVPNManager|NETunnelProviderManager|NEPacketTunnelProvider|NETunnelProviderSession)\b")
        for path, text in texts.items():
            for match in vpn.finditer(text):
                lineno = text.count("\n", 0, match.start()) + 1
                window = text[max(0, match.start() - 4000):match.start()]
                guarded = "CMUX_MOBILE_PRODUCTION" in window or "#if DEBUG" in window
                if not guarded:
                    self.add("api.vpn-source", "2.5.1", "warning" if self.lane == "appstore" else "info",
                             f"{match.group(0)} used in the NEXT app; the system VPN API cost a rejection before and the App Store binary must not contain it",
                             f"{self.rel(path)}:{lineno}")

        # 2.1: placeholder copy in user-facing strings (one catalog per kit module).
        # Case-sensitive TODO/FIXME: "Todo" is the name of a feature here.
        bad = re.compile(r"\b(TODO|FIXME|XXX)\b|(?i:lorem ipsum|coming soon|\bplaceholder text\b)")
        for loc in sorted(self.root.glob(LOCALIZABLE_GLOB)):
            try:
                strings = json.loads(loc.read_text())
            except json.JSONDecodeError:
                self.add("copy.catalog", "2.1", "blocker", "string catalog does not parse", self.rel(loc))
                continue
            for key, entry in (strings.get("strings") or {}).items():
                value = (((entry or {}).get("localizations") or {}).get("en") or {}).get("stringUnit", {}).get("value", key)
                if isinstance(value, str) and bad.search(value):
                    self.add("copy.placeholder", "2.1", "blocker", f"user-facing string looks unfinished: {value[:80]!r}", f"{self.rel(loc)} [{key}]")

        # URLs the app opens.
        url_literal = re.compile(r"\"(https://[^\"\\\s]+)\"")
        for path, text in texts.items():
            for match in url_literal.finditer(text):
                url = match.group(1)
                if self.ignorable_url(url):
                    continue
                lineno = text.count("\n", 0, match.start()) + 1
                urls.append((url, "source", f"{self.rel(path)}:{lineno}"))
        return urls

    @staticmethod
    def ignorable_url(url: str) -> bool:
        host = re.sub(r"^https://", "", url).split("/")[0].lower()
        if any(s in url for s in ("\\(", "{", "<", "%@", "%s", "example.", "localhost", "127.0.0.1", "/auth/callback", "@")):
            return True
        if url.endswith(".git") or "github.com/apple/" in url:
            return True
        # API endpoints are not pages a reviewer opens; the reviewer path covers them.
        if host.startswith(("api.", "cloud-api.", "iroh", "relay", "presence")) or "/api/" in url:
            return True
        return host.endswith((".ts.net", ".internal", ".local", "apple.com", "icloud.com", "googleapis.com",
                              ".workers.dev", ".vercel.app", "sentry.io"))

    def check_apple_sign_in_ships(self) -> None:
        """Debug builds hide the Apple button (CMUX_MOBILE_APPLE_SIGN_IN = NO);
        the App Store configurations must turn it on and carry the entitlement,
        or the shipped app offers Google and GitHub without Apple (4.8)."""
        self.ran("signin-apple-shipping")
        project = self.root / PROJECT_YML
        text = project.read_text(errors="ignore") if project.is_file() else ""
        if not re.search(r"CMUX_MOBILE_APPLE_SIGN_IN:\s*\"?YES", text):
            self.add("signin.apple-shipping", "4.8", "blocker",
                     "no configuration sets CMUX_MOBILE_APPLE_SIGN_IN to YES, so the shipped app hides Sign in with Apple", PROJECT_YML)
        ents = self.root / APPSTORE_ENTITLEMENTS[0]
        if ents.is_file():
            try:
                body = plistlib.loads(ents.read_bytes())
            except plistlib.InvalidFileException:
                body = {}
            if "com.apple.developer.applesignin" not in body:
                self.add("signin.apple-entitlement", "4.8", "blocker",
                         "the App Store entitlements lack com.apple.developer.applesignin", APPSTORE_ENTITLEMENTS[0])

    def store_rules(self):
        """scripts/cmux-next/check-app-store-rules.py from the judged source:
        the rules App Store Connect enforces in processing (ITMS-90626,
        90683, 90474). None when the source has no copy."""
        path = self.root / STORE_RULES
        if not path.is_file():
            return None
        import importlib.util  # noqa: PLC0415
        spec = importlib.util.spec_from_file_location("cmux_next_store_rules", path)
        if spec is None or spec.loader is None:
            return None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module

    def project_info(self) -> dict:
        """The CmuxMobileApp Info.plist properties as project.yml declares them."""
        rules = self.store_rules()
        project = self.root / PROJECT_YML
        if rules is not None and project.is_file():
            return rules.project_info(project)
        return {}

    def check_store_rules(self, app: Path | None = None) -> None:
        self.ran("app-store-connect-processing")
        rules = self.store_rules()
        if rules is None:
            self.add("processing.unchecked", "2.1", "warning",
                     f"{STORE_RULES} is missing from this source, so the processing rules were not run", STORE_RULES)
            return
        findings = rules.Findings()
        if app is None:
            rules.check_source(self.root, findings)
        else:
            rules.check_app(app, findings)
        for line in findings.lines:
            where, _, rest = line.partition(": ")
            rule, _, text = rest.partition(": ")
            self.add(f"processing.{rule}", "2.1 (ITMS)", "blocker",
                     f"App Store Connect would refuse this build in processing: {text}", where)

    # --------------------------------------------------------------- plist

    def check_info_plist(self, plist: dict, where: str) -> None:
        self.ran("info-plist")
        usage = {
            "NSCameraUsageDescription": (r"AVCaptureDevice|AVCaptureSession|DataScannerViewController", "camera"),
            "NSMicrophoneUsageDescription": (r"AVAudioRecorder|AVAudioEngine|requestRecordPermission|AVAudioApplication\.requestRecordPermission", "microphone"),
            "NSSpeechRecognitionUsageDescription": (r"SFSpeechRecognizer", "speech recognition"),
            "NSPhotoLibraryUsageDescription": (r"PHPhotoLibrary\.(requestAuthorization|shared)", "photo library"),
            "NSPhotoLibraryAddUsageDescription": (r"UIImageWriteToSavedPhotosAlbum|PHAssetChangeRequest", "saving photos"),
            "NSLocationWhenInUseUsageDescription": (r"CLLocationManager", "location"),
            "NSContactsUsageDescription": (r"CNContactStore", "contacts"),
            "NSCalendarsUsageDescription": (r"EKEventStore", "calendars"),
            "NSBluetoothAlwaysUsageDescription": (r"CBCentralManager|CBPeripheralManager", "Bluetooth"),
            "NSFaceIDUsageDescription": (r"LAContext|evaluatePolicy\(\.deviceOwnerAuthentication", "Face ID"),
            "NSUserTrackingUsageDescription": (r"ATTrackingManager", "tracking"),
            "NSLocalNetworkUsageDescription": (r"NWBrowser|NWListener|NetServiceBrowser|_udp|Bonjour", "local network"),
        }
        joined = "\n".join(self.texts().values())
        for key, (pattern, label) in usage.items():
            uses = re.search(pattern, joined) is not None
            value = plist.get(key)
            if uses and not value:
                self.add("privacy.purpose-string", "5.1.1", "blocker",
                         f"the app uses the {label} API but {key} is missing", where)
            elif value and (len(value) < 25 or re.fullmatch(r"(?i).*\b(needs?|requires?) (access|permission)\b.*", value)):
                self.add("privacy.purpose-string-vague", "5.1.1", "warning",
                         f"{key} is too generic for App Review: {value!r}", where)
        if "NSLocalNetworkUsageDescription" in plist and not plist.get("NSBonjourServices"):
            self.add("privacy.bonjour", "5.1.1", "warning", "local network purpose string without NSBonjourServices", where)
        if "ITSAppUsesNonExemptEncryption" not in plist:
            self.add("export.encryption", "2.1", "warning", "ITSAppUsesNonExemptEncryption is not declared", where)
        ats = plist.get("NSAppTransportSecurity") or {}
        if ats.get("NSAllowsArbitraryLoads"):
            self.add("ats.arbitrary-loads", "2.5.1", "blocker", "NSAllowsArbitraryLoads is true; App Review asks for a justification", where)
        if plist.get("UIRequiredDeviceCapabilities") and "ipad" not in json.dumps(plist).lower():
            pass

    def check_entitlements(self, ents: dict, where: str) -> None:
        self.ran("entitlements")
        if self.lane == "appstore":
            for key in ents:
                if key.startswith("com.apple.developer.networking.networkextension") or key.startswith("com.apple.developer.networking.vpn"):
                    self.add("entitlement.vpn", "2.5.1", "blocker",
                             f"the App Store binary carries {key}; the system VPN API was rejected before", where)
            if ents.get("get-task-allow") is True:
                self.add("entitlement.debug", "2.1", "blocker", "get-task-allow is true (a debug-signed build)", where)
            if ents.get("aps-environment") not in (None, "production"):
                self.add("entitlement.aps", "2.1", "blocker", f"aps-environment is {ents.get('aps-environment')!r}, not production", where)

    # ---------------------------------------------------------------- binary

    def check_app_bundle(self, app: Path) -> None:
        self.ran("binary")
        info_path = app / "Info.plist"
        if not info_path.is_file():
            self.add("binary.info-plist", "2.1", "blocker", "the bundle has no Info.plist", str(app))
            return
        info = plistlib.loads(info_path.read_bytes())
        self.check_info_plist(info, f"{app.name}/Info.plist")
        if info.get("CmuxMobileAppleSignIn") not in ("YES", "1", True, "true"):
            self.add("binary.apple-sign-in", "4.8", "blocker",
                     f"CmuxMobileAppleSignIn is {info.get('CmuxMobileAppleSignIn')!r}: this binary hides Sign in with Apple "
                     "while offering Google and GitHub", f"{app.name}/Info.plist")
        self.check_store_rules(app)
        if not any(app.rglob("PrivacyInfo.xcprivacy")):
            self.add("privacy.manifest", "5.1.2", "blocker", "no PrivacyInfo.xcprivacy in the bundle (required-reason APIs)", app.name)
        self.check_entitlements(self.entitlements(app), f"{app.name} (signed entitlements)")
        for appex in sorted((app / "PlugIns").glob("*.appex")) if (app / "PlugIns").is_dir() else []:
            try:
                ext = plistlib.loads((appex / "Info.plist").read_bytes())
            except (OSError, plistlib.InvalidFileException):
                continue
            point = (ext.get("NSExtension") or {}).get("NSExtensionPointIdentifier", "")
            if self.lane == "appstore" and point.startswith("com.apple.networkextension"):
                self.add("binary.vpn-extension", "2.5.1", "blocker", f"{appex.name} is a Network Extension ({point})", appex.name)
            self.check_entitlements(self.entitlements(appex), f"{appex.name} (signed entitlements)")
        executables = [app / info.get("CFBundleExecutable", app.stem)]
        executables += [p / p.stem for p in (app / "Frameworks").glob("*.framework")] if (app / "Frameworks").is_dir() else []
        executables += [p / p.stem for p in (app / "PlugIns").glob("*.appex")] if (app / "PlugIns").is_dir() else []
        needles = {
            b"PrivateFrameworks/": ("api.private-framework", "2.5.1", "blocker", "links or loads a private framework"),
            b"NEVPNManager": ("api.vpn", "2.5.1", "blocker", "contains NEVPNManager"),
            b"NETunnelProviderManager": ("api.vpn", "2.5.1", "blocker", "contains NETunnelProviderManager"),
            b"NEPacketTunnelProvider": ("api.vpn", "2.5.1", "blocker", "contains NEPacketTunnelProvider"),
            b"checkout.stripe.com": ("iap.external-purchase-binary", "3.1.1", "blocker", "contains a Stripe checkout URL"),
            b"billing.stripe.com": ("iap.external-purchase-binary", "3.1.1", "blocker", "contains a Stripe billing URL"),
            b"_LSApplicationWorkspace": ("api.private-symbol", "2.5.1", "blocker", "references LSApplicationWorkspace (private)"),
            b"UIGetScreenImage": ("api.private-symbol", "2.5.1", "blocker", "references UIGetScreenImage (private)"),
        }
        for exe in executables:
            if not exe.is_file():
                continue
            data = exe.read_bytes()
            for needle, (rule, guideline, severity, label) in needles.items():
                if needle in data:
                    if rule == "api.vpn" and self.lane != "appstore":
                        continue
                    self.add(rule, guideline, severity, f"{exe.name} {label}", self.rel(exe) if exe.is_relative_to(self.root) else str(exe.relative_to(app.parent)))

    @staticmethod
    def entitlements(bundle: Path) -> dict:
        if shutil.which("codesign"):
            proc = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(bundle)], capture_output=True)
            if proc.returncode == 0 and proc.stdout.strip():
                try:
                    return plistlib.loads(proc.stdout)
                except plistlib.InvalidFileException:
                    pass
        # Linux: the embedded profile carries the granted entitlements, and the
        # code signature carries the XML entitlements blob.
        candidates = [bundle / "embedded.mobileprovision"]
        info = bundle / "Info.plist"
        if info.is_file():
            try:
                exe = plistlib.loads(info.read_bytes()).get("CFBundleExecutable")
                if exe:
                    candidates.insert(0, bundle / exe)
            except plistlib.InvalidFileException:
                pass
        for path in candidates:
            if not path.is_file():
                continue
            data = path.read_bytes()
            for match in re.finditer(rb"<\?xml.*?</plist>", data, re.S):
                try:
                    body = plistlib.loads(match.group(0))
                except plistlib.InvalidFileException:
                    continue
                if path.suffix == ".mobileprovision":
                    return body.get("Entitlements", {})
                if any(k in body for k in ("application-identifier", "aps-environment", "keychain-access-groups")):
                    return body
        return {}

    # ------------------------------------------------------------------ urls

    def check_urls(self, urls: list[tuple[str, str, str]]) -> list[dict]:
        self.ran("urls")
        seen: dict[str, dict] = {}
        results = []
        for url, field, where in urls:
            if url not in seen:
                seen[url] = fetch(url)
            result = dict(seen[url], field=field, where=where)
            results.append(result)
            status = result["status"]
            critical = field in ("supportUrl", "privacyPolicyUrl", "marketingUrl") or "cmux.com" in url
            if status != 200:
                self.add("url.status", "1.5" if field == "supportUrl" else "5.1.1" if "privacy" in url else "2.1",
                         "blocker" if critical else "warning",
                         f"{url} returned {status or result.get('error')}", where)
            elif result.get("looks_like_error"):
                self.add("url.error-page", "1.5", "blocker" if critical else "warning",
                         f"{url} returns 200 but the page reads like an error page ({result.get('title')!r})", where)
            elif field == "supportUrl" and not result.get("has_contact"):
                self.add("url.support-contact", "1.5", "blocker",
                         f"{url} has no way to contact us (no email address or form)", where)
        return list({r["url"]: r for r in results}.values())

    # --------------------------------------------------------------- history

    def check_history(self) -> list[dict]:
        """Every past rejection names a detector (a lint rule, a UI test, or a
        workflow check) and that detector still exists."""
        self.ran("rejection-history")
        path = self.root / HISTORY_FILE
        if not path.is_file():
            self.add("history.missing", "-", "blocker", "the rejection history file is missing", HISTORY_FILE)
            return []
        history = json.loads(path.read_text())
        tests_text = "\n".join(p.read_text(errors="ignore") for p in (self.root / UITEST_DIR).glob("*.swift"))
        script_text = Path(__file__).read_text()
        workflows = "\n".join(p.read_text(errors="ignore") for p in (self.root / ".github/workflows").glob("ios-*.yml"))
        for entry in history.get("rejections", []):
            for detector in entry.get("detectors", []):
                kind, _, name = detector.partition(":")
                present = {
                    "lint": f'"{name}"' in script_text,
                    "uitest": f"func {name}(" in tests_text,
                    "workflow": name in workflows,
                }.get(kind, False)
                if not present:
                    self.add("history.detector-missing", entry.get("guideline", "-"), "blocker",
                             f"rejection {entry.get('date')} ({entry.get('summary')}) names detector {detector}, which no longer exists",
                             HISTORY_FILE)
            if not entry.get("detectors"):
                self.add("history.no-detector", entry.get("guideline", "-"), "blocker",
                         f"rejection {entry.get('date')} ({entry.get('summary')}) has no detector", HISTORY_FILE)
        return history.get("rejections", [])


def fetch(url: str) -> dict:
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
        "Accept": "text/html,*/*",
    })
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            body = resp.read(2_000_000).decode("utf-8", "ignore")
            status = resp.status
            final = resp.geturl()
    except urllib.error.HTTPError as exc:
        return {"url": url, "status": exc.code, "final_url": url, "title": "", "error": str(exc)}
    except Exception as exc:  # noqa: BLE001 - network errors are findings
        return {"url": url, "status": 0, "final_url": url, "title": "", "error": f"{type(exc).__name__}: {exc}"}
    title_match = re.search(r"<title[^>]*>(.*?)</title>", body, re.S | re.I)
    title = html.unescape(title_match.group(1).strip()) if title_match else ""
    text = re.sub(r"<[^>]+>", " ", re.sub(r"(?s)<(script|style).*?</\1>", " ", body))
    return {
        "url": url,
        "status": status,
        "final_url": final,
        "title": title,
        "looks_like_error": bool(re.search(r"\b(404|not found|page not found|500|error)\b", title, re.I)),
        "has_contact": bool(re.search(r"[\w.+-]+@[\w-]+\.[\w.]+", text) or "<form" in body.lower() or "mailto:" in body.lower()),
    }


def config_block(text: str, name: str) -> str | None:
    """project.yml's `settings: configs: NAME:` block (indent 4), or None."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if line == f"    {name}:":
            out = []
            for follow in lines[i + 1:]:
                if follow.strip() and len(follow) - len(follow.lstrip()) <= 4:
                    break
                out.append(follow)
            return "\n".join(out)
    return None


def marketing_version(root: Path, lane: str) -> str:
    """The version App Store Connect holds for this lane: the AppStore
    configuration's MARKETING_VERSION for appstore, else the base one."""
    text = (root / PROJECT_YML).read_text(errors="ignore")
    pattern = re.compile(r"^\s*MARKETING_VERSION:\s*\"?([0-9][0-9.]*)", re.M)
    if lane == "appstore":
        block = config_block(text, APPSTORE_CONFIG)
        found = pattern.search(block or "")
        if found:
            return found.group(1)
    found = pattern.search(text)
    return found.group(1) if found else ""


def unpack_ipa(ipa: Path) -> Path:
    tmp = Path(tempfile.mkdtemp(prefix="app-review-ipa-"))
    with zipfile.ZipFile(ipa) as zf:
        zf.extractall(tmp)
    apps = list((tmp / "Payload").glob("*.app"))
    if not apps:
        raise SystemExit(f"{ipa} has no Payload/*.app")
    return apps[0]


def cmd_lint(args: argparse.Namespace) -> int:
    root = Path(args.source_root).resolve()
    lint = Lint(root, args.lane)
    urls = lint.check_metadata()
    if lint.check_next_app_present():
        if args.lane == "appstore":
            lint.check_appstore_config()
        urls += lint.check_sources()
        lint.check_info_plist(lint.project_info(), PROJECT_YML)
        lint.check_store_rules()
        for rel in APPSTORE_ENTITLEMENTS:
            if args.lane == "appstore" and (root / rel).is_file():
                lint.check_entitlements(plistlib.loads((root / rel).read_bytes()), rel)
    app = None
    if args.ipa:
        app = unpack_ipa(Path(args.ipa))
    elif args.app:
        app = Path(args.app)
    if app:
        lint.check_app_bundle(app)
    url_results = lint.check_urls(urls) if args.check_urls else []
    history = lint.check_history()
    result = {
        "lane": args.lane,
        "binary": str(app) if app else None,
        "checked": sorted(set(lint.checked)),
        "findings": [f.as_dict() for f in lint.findings],
        "urls": url_results,
        "history": history,
    }
    if args.json:
        Path(args.json).write_text(json.dumps(result, indent=2))
    md = render([dict(f, source="lint") for f in result["findings"]], result, None, [])
    print(md)
    return 1 if any(f.severity == "blocker" for f in lint.findings) else 0


# ------------------------------------------------------------------ report

def asc_findings(path: Path) -> list[dict]:
    """`asc validate --output json`: every check that is blocking (or any
    warning under --strict) is a blocker for us; Apple's own tool says so."""
    raw = path.read_text()
    try:
        body = json.loads(raw)
    except json.JSONDecodeError:
        return [{"rule": "asc.unparsed", "guideline": "2.1", "severity": "blocker", "source": "asc validate",
                 "message": "asc validate output did not parse; read the log", "where": str(path)}]
    # asc's JSON shape varies by subcommand: take every object that carries
    # a severity, wherever it sits.
    checks: list[dict] = []

    def collect(node: object) -> None:
        if isinstance(node, dict):
            if "severity" in node and ("message" in node or "title" in node):
                checks.append(node)
                return
            for value in node.values():
                collect(value)
        elif isinstance(node, list):
            for value in node:
                collect(value)

    collect(body)
    out = []
    for c in checks:
        sev = str(c.get("severity", "")).lower()
        blocking = c.get("blocking") in (True, "true") or sev in ("error", "warning")
        out.append({
            "rule": f"asc.{c.get('code') or c.get('id') or c.get('check') or 'check'}",
            "guideline": guideline_for_asc(str(c.get("code") or c.get("id") or c.get("check") or "")),
            "severity": "blocker" if blocking else "info",
            "source": f"asc ({path.stem})",
            "message": c.get("message") or c.get("title") or json.dumps(c)[:200],
            "where": c.get("resource") or c.get("resourceId") or "",
        })
    return out


def guideline_for_asc(code: str) -> str:
    if code.startswith("privacy"):
        return "5.1.1"
    if code.startswith(("screenshots", "metadata")):
        return "2.3"
    return "2.1"


def read_input(path: Path, source: str) -> tuple[object | None, list[dict]]:
    """A report input's JSON, or a blocker naming it: an export that failed
    leaves an empty or partial file, and the report must still be written."""
    try:
        return json.loads(path.read_text()), []
    except (OSError, ValueError) as error:
        return None, [{"rule": "input.unreadable", "guideline": "2.1", "severity": "blocker", "source": source,
                       "message": f"{path.name} did not parse ({error.__class__.__name__}), so this input is unjudged",
                       "where": str(path)}]


GATE_NOTE = re.compile(r"^GATE-NOTE ([\w.-]+): (.+)$")


def suite_log_findings(path: Path) -> list[dict]:
    """`GATE-NOTE name: message` lines a suite printed: what it could not judge."""
    family = path.stem
    seen: set[str] = set()
    out: list[dict] = []
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return out
    for line in lines:
        match = GATE_NOTE.match(line.strip())
        if not match or match.group(1) in seen:
            continue
        seen.add(match.group(1))
        out.append({"rule": f"uitest.unjudged.{match.group(1)}", "guideline": "2.1(a)", "severity": "warning",
                    "source": f"reviewer-path suite ({family})", "message": match.group(2), "where": family})
    return out


def xcresult_findings(path: Path) -> list[dict]:
    """JSON from `xcrun xcresulttool get test-results tests --path X.xcresult`."""
    body, unreadable = read_input(path, f"reviewer-path suite ({path.stem})")
    if body is None:
        return unreadable
    out: list[dict] = []
    device = path.stem

    def walk(node: dict, trail: list[str]) -> None:
        name = node.get("name", "")
        kids = node.get("children") or []
        if node.get("nodeType") == "Test Case":
            if node.get("result") == "Skipped":
                reason = "; ".join(k.get("name", "") for k in kids)[:300]
                out.append({
                    "rule": "uitest.skipped", "guideline": "2.1(a)", "severity": "warning",
                    "source": f"reviewer-path suite ({device})",
                    "message": f"{'/'.join(trail[-1:] + [name])} skipped: {reason or 'no reason given'}", "where": device,
                })
                return
            if node.get("result") == "Failed":
                detail = "; ".join(
                    k.get("name", "") for k in kids if k.get("nodeType") == "Failure Message"
                )[:400]
                guideline = "2.1(a)"
                if "DeadControl" in name or "dead" in detail.lower():
                    guideline = "2.1(a) dead control"
                out.append({
                    "rule": "uitest.failed", "guideline": guideline, "severity": "blocker",
                    "source": f"reviewer-path suite ({device})",
                    "message": f"{'/'.join(trail[-1:] + [name])}: {detail or 'failed'}", "where": device,
                })
            return
        for k in kids:
            walk(k, trail + [name] if name else trail)

    ran = 0

    def count(node: dict) -> None:
        nonlocal ran
        if node.get("nodeType") == "Test Case":
            ran += 1
        for k in node.get("children") or []:
            count(k)

    for root in body.get("testNodes", []):
        count(root)
        walk(root, [])
    if ran == 0:
        # An empty result (the suite never started, a crash before the first
        # test) is never a pass.
        out.append({
            "rule": "uitest.none-ran", "guideline": "2.1(a)", "severity": "blocker",
            "source": f"reviewer-path suite ({device})",
            "message": f"the {device} suite ran no tests, so the reviewer path is unjudged there", "where": device,
        })
    return out


def render(findings: list[dict], lint: dict | None, asc: list[dict] | None, tests: list[str]) -> str:
    findings = sorted(findings, key=lambda f: (SEVERITY_ORDER.get(f["severity"], 9), f.get("guideline", ""), f.get("rule", "")))
    blockers = [f for f in findings if f["severity"] == "blocker"]
    lines = ["## Would Apple accept this build right now?", ""]
    lines.append(f"**{'NO' if blockers else 'YES'}**: {len(blockers)} blocking, "
                 f"{sum(f['severity'] == 'warning' for f in findings)} warnings, "
                 f"{sum(f['severity'] == 'info' for f in findings)} notes.")
    lines.append("")
    if findings:
        lines += ["| # | Severity | Guideline | Source | Finding | Where |", "|---|---|---|---|---|---|"]
        for i, f in enumerate(findings, 1):
            msg = str(f["message"]).replace("|", "\\|").replace("\n", " ")
            lines.append(f"| {i} | {f['severity']} | {f.get('guideline', '')} | {f.get('source', '')} | {msg} | `{f.get('where', '')}` |")
        lines.append("")
    if lint:
        lines.append(f"Checked: {', '.join(lint.get('checked', []))}; binary: `{lint.get('binary') or 'not given'}`.")
        if lint.get("urls"):
            lines += ["", "<details><summary>URLs</summary>", "", "| URL | Status | Title |", "|---|---|---|"]
            for u in lint["urls"]:
                lines.append(f"| {u['url']} | {u['status']} | {str(u.get('title', ''))[:60]} |")
            lines += ["", "</details>"]
    if tests:
        lines.append(f"Test results read: {', '.join(tests)}.")
    if asc is None:
        lines.append("`asc validate` result: not given.")
    return "\n".join(lines)


def cmd_report(args: argparse.Namespace) -> int:
    findings: list[dict] = []
    lint = None
    for item in args.lint or []:
        body, unreadable = read_input(Path(item), "guideline lint")
        findings += unreadable
        if body is None:
            continue
        lint = lint or body
        findings += [dict(f, source=f"guideline lint ({body.get('lane')})") for f in body["findings"]]
    asc = None
    for item in args.asc_validate or []:
        if Path(item).is_file():
            asc = (asc or []) + asc_findings(Path(item))
    if asc:
        findings += asc
    if asc is None and not args.asc_skipped:
        findings.append({"rule": "asc.missing", "guideline": "2.1", "severity": "blocker", "source": "asc validate",
                         "message": "asc validate did not run, so App Store Connect readiness is unknown", "where": ""})
    tests = []
    for x in args.xcresult_json or []:
        p = Path(x)
        if p.is_file():
            tests.append(p.stem)
            findings += xcresult_findings(p)
        else:
            findings.append({"rule": "uitest.missing", "guideline": "2.1(a)", "severity": "blocker",
                             "source": "reviewer-path suite", "message": f"no test result at {x}: the suite did not run", "where": x})
    for extra in args.extra or []:
        body, unreadable = read_input(Path(extra), "agent reviewer pass")
        findings += unreadable + [dict(f) for f in (body or [])]
    for log in args.suite_log:
        findings += suite_log_findings(Path(log))
    for item in args.suite_status:
        status, unreadable = read_input(Path(item), "reviewer-path suite")
        findings += unreadable
        if not isinstance(status, dict):
            continue
        family = status.get("family", "")
        failed_here = any(f.get("rule") == "uitest.failed" and f.get("where") == family for f in findings)
        if status.get("exit", 0) != 0 and not failed_here:
            findings.append({"rule": "uitest.suite-failed", "guideline": "2.1(a)", "severity": "blocker",
                             "source": f"reviewer-path suite ({family})",
                             "message": f"xcodebuild exited {status.get('exit')} on {family} with no failed test in its result: read {family}.log",
                             "where": family})
    # Fail closed: a check that left no result is never a pass (run
    # 42799920852 said YES because its inputs never reached the report).
    if args.expect_lint and lint is None:
        findings.append({"rule": "lint.missing", "guideline": "2.1", "severity": "blocker", "source": "guideline lint",
                         "message": "the guideline lint left no result, so the build is unjudged", "where": ""})
    for family in args.expect_device:
        if family not in tests:
            findings.append({"rule": "uitest.missing", "guideline": "2.1(a)", "severity": "blocker",
                             "source": "reviewer-path suite",
                             "message": f"no {family} suite result reached the report: the reviewer path is unjudged there",
                             "where": family})
    md = render(findings, lint, asc, tests)
    if args.out:
        Path(args.out).write_text(md + "\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            fh.write(md + "\n")
    print(md)
    return 1 if any(f["severity"] == "blocker" for f in findings) else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    lint = sub.add_parser("lint")
    lint.add_argument("--source-root", default=".")
    lint.add_argument("--lane", choices=("appstore", "internal"), default="appstore")
    lint.add_argument("--app")
    lint.add_argument("--ipa")
    lint.add_argument("--check-urls", action="store_true")
    lint.add_argument("--json")
    report = sub.add_parser("report")
    report.add_argument("--lint", action="append")
    report.add_argument("--asc-validate", action="append")
    report.add_argument("--asc-skipped", action="store_true",
                        help="asc validate cannot run for this event (a PR has no release secrets)")
    report.add_argument("--xcresult-json", action="append")
    report.add_argument("--extra", action="append", help="JSON list of findings from another check")
    report.add_argument("--suite-log", action="append", default=[],
                        help="a suite's xcodebuild log; its GATE-NOTE lines become warnings")
    report.add_argument("--suite-status", action="append", default=[],
                        help="{family, exit} from the suite step: a nonzero exit with no failed test blocks")
    report.add_argument("--expect-lint", action="store_true",
                        help="a missing --lint result is a blocker: the gate fails closed")
    report.add_argument("--expect-device", action="append", default=[],
                        help="a device family (iphone, ipad) whose suite result must be present")
    report.add_argument("--out")
    version = sub.add_parser("version")
    version.add_argument("--source-root", default=".")
    version.add_argument("--lane", choices=("appstore", "internal"), default="appstore")
    args = parser.parse_args(argv)
    if args.cmd == "version":
        found = marketing_version(Path(args.source_root), args.lane)
        print(found)
        return 0 if found else 1
    return cmd_lint(args) if args.cmd == "lint" else cmd_report(args)


if __name__ == "__main__":
    sys.exit(main())
