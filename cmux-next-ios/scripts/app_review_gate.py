#!/usr/bin/env python3
"""App Review before Apple: one ranked list of everything that would get the
cmux NEXT iOS app (cmux-next-ios, CmuxMobileApp) rejected, from what a machine
can check.

Two subcommands:

  lint    Static guideline checks on the metadata, the cmux-next-ios source
          tree, and (when given) the exact .app or .ipa to be submitted:
          Info.plist purpose strings (from project.yml, which xcodegen turns
          into the plist), entitlements, extensions, binary symbols, external
          purchase links, the subscription rules (Restore Purchases, the 3.1.2
          renewal terms and Terms link, review notes that say where the plans
          are), account deletion, Sign in with Apple in the shipping
          configuration, App Store Connect processing rules
          (scripts/cmux-next/check-app-store-rules.py), URLs (with
          --check-urls), and the rejection-history coverage check (every past
          rejection names a detector that still exists).

  report  Merge lint JSON, xcresult test outcomes and `asc validate` JSON into
          one ranked Markdown list (blocking first). Exit 1 when anything
          blocks. This is the list nothing is submitted past. With
          --known-blockers (a push or pull request), exit 1 only when a
          blocker is new: one not in known-blockers.json, the app's blockers
          at the time it was written, each owned by a fix in flight.

The NEXT app sells cmux Go, Pro and Max as auto-renewable App Store
subscriptions (Packages/iOS/CmuxMobileBilling: Settings > Plan opens the plans
screen). When the judged sources use StoreKit, the subscription rules apply:
Restore Purchases (3.1.1), the renewal terms with Terms of Use and Privacy
Policy links on the plans screen and a Terms link in the store listing (3.1.2),
and review notes that say where the plans are and how to restore (2.1(b), the
2026-11-07 "could not locate the in-app purchases"). An outside purchase link is
a 3.1.1 rejection whether or not the app sells anything.

Standard library only; runs on Linux (metadata, source, URLs, plist and
Mach-O string scans) and macOS (adds codesign/otool when present).

Usage:
  cmux-next-ios/scripts/app_review_gate.py lint --source-root . --lane appstore \
      [--app path/CmuxMobileApp.app | --ipa path/CmuxMobileApp.ipa] [--check-urls] [--json out.json]
  cmux-next-ios/scripts/app_review_gate.py report --lint lint.json \
      [--xcresult-json tests.json ...] [--asc-validate asc.json] [--asc-versions versions.json] [--out report.md]
  cmux-next-ios/scripts/app_review_gate.py version --source-root .   # the version asc validates

Lanes: appstore (the AppStore configuration, com.cmux.app), internal (cmux
INTERNAL's TestFlight builds; the lighter checks) and internal-submission
(cmux INTERNAL, dev.cmux.app.internal, judged as an App Store submission with
every appstore check).
"""

from __future__ import annotations

import argparse
import dataclasses
import html
import http.client
import ipaddress
import json
import os
import plistlib
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
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
    # Settings > Plan and the plans screen: the App Store subscriptions.
    "Packages/iOS/CmuxMobileBilling/Sources",
    # CmuxMobileSystemUI.framework: every StoreKit, AuthenticationServices,
    # SafariServices, PhotosUI and QuickLook call, embedded but not linked.
    "cmux-next-ios/SystemUI",
)
LOCALIZABLE_GLOB = "cmux-next-ios/CmuxMobileKit/Sources/*/Resources/Localizable.xcstrings"
# The purpose-string check reads every Swift file the app links, not only the
# folders above: the kit's local packages (Packages/iOS/*, Packages/Shared/*)
# and theirs, found from the `.package(path:)` lines of each Package.swift and
# the `packages:` paths in project.yml. A privacy API that moved into a shared
# package (the microphone in CmuxChiefVoiceCore, the camera in CmuxScreenKit,
# dictation in CmuxMobileSupport) is still the app's prompt.
LINKED_PACKAGE_ROOTS = ("cmux-next-ios/CmuxMobileKit",)
PACKAGE_PATH_RE = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?path:\s*"([^"]+)"')
PROJECT_PACKAGE_PATH_RE = re.compile(r"^\s{4}path:\s*(\.\./Packages/\S+|CmuxMobileKit)\s*$", re.M)
# The NEXT app's App Store review package (metadata, screenshots, reviewer
# notes) and the rejection history live beside the app.
REVIEW_DIR = "cmux-next-ios/AppStoreReview"
# Every bundle Apple scans needs a privacy manifest that declares the
# required-reason APIs linked into it (ITMS-91053 refuses the upload otherwise).
# The app's manifest covers every source the lint reads; each extension's covers
# its own folder.
PRIVACY_MANIFESTS = {
    "cmux-next-ios/App/PrivacyInfo.xcprivacy": None,
    "cmux-next-ios/NotificationContent/PrivacyInfo.xcprivacy": "cmux-next-ios/NotificationContent",
    "cmux-next-ios/NotificationService/PrivacyInfo.xcprivacy": "cmux-next-ios/NotificationService",
}
# https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
REQUIRED_REASON_APIS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": r"\bUserDefaults\b|@AppStorage\b|NSUserDefaults",
    "NSPrivacyAccessedAPICategoryFileTimestamp":
        r"\b(creationDate|modificationDate|contentModificationDate|fileModificationDate)(Key)?\b|\b(f|l)?stat\(|getattrlist",
    "NSPrivacyAccessedAPICategorySystemBootTime": r"\bsystemUptime\b|mach_absolute_time\(",
    "NSPrivacyAccessedAPICategoryDiskSpace":
        r"volume(Available|Total)Capacity|systemFreeSize|systemSize\b|\bstatv?fs\(",
    "NSPrivacyAccessedAPICategoryActiveKeyboards": r"activeInputModes",
}
# The reason codes Apple accepts for each category (same page). A code that is
# not in its category's list makes the manifest invalid (ITMS-91056); the
# third-party-SDK codes (C56D.1, 0A2A.1) are never right in an app's own bundle.
REQUIRED_REASON_CODES = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1", "8FFB.1", "3D61.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {"3EC4.1", "54BD.1"},
}
SDK_ONLY_REASON_CODES = {"C56D.1", "0A2A.1"}
# CA92.1 covers defaults only the app itself reads; defaults shared through an
# App Group (the app writes, an extension reads) need 1C8F.1. These are the
# calls that reach the App Group's suite: UserDefaults(suiteName:) itself and
# the kit's wrappers around it (PushActions.sharedDefaults,
# PushSharedPreference.live), which an extension's own folder calls.
APP_GROUP_DEFAULTS = re.compile(r"UserDefaults\(suiteName:|\bsharedDefaults\(|PushSharedPreference\.live\(")
APP_GROUP_DEFAULTS_REASON = "1C8F.1"
# https://developer.apple.com/documentation/bundleresources/describing-data-use-in-privacy-manifests
COLLECTED_DATA_TYPES = {f"NSPrivacyCollectedDataType{name}" for name in (
    "Name", "EmailAddress", "PhoneNumber", "PhysicalAddress", "OtherUserContactInfo", "Health", "Fitness",
    "PaymentInfo", "CreditInfo", "OtherFinancialInfo", "PreciseLocation", "CoarseLocation", "SensitiveInfo",
    "Contacts", "EmailsOrTextMessages", "PhotosorVideos", "AudioData", "GameplayContent", "CustomerSupport",
    "OtherUserContent", "BrowsingHistory", "SearchHistory", "UserID", "DeviceID", "PurchaseHistory",
    "ProductInteraction", "AdvertisingData", "OtherUsageData", "CrashData", "PerformanceData",
    "OtherDiagnosticData", "EnvironmentScanning", "Hands", "Head", "OtherDataTypes")}
COLLECTED_DATA_PURPOSES = {f"NSPrivacyCollectedDataTypePurpose{name}" for name in (
    "ThirdPartyAdvertising", "DeveloperAdvertising", "Analytics", "ProductPersonalization", "AppFunctionality",
    "Other")}
# 2.5.4: a UIBackgroundModes value the app declares must be used for its
# purpose. Each mode -> the API that uses it (in any source the app links).
BACKGROUND_MODE_APIS = {
    "audio": r"\.playback\b|\.playAndRecord\b|AVAudioSession\.Category\.(playback|playAndRecord)",
    "location": r"\bCLLocationManager\b",
    "voip": r"\bPKPushRegistry\b|\bCXProvider\b",
    "fetch": r"\bBGAppRefreshTask(Request)?\b|setMinimumBackgroundFetchInterval",
    "processing": r"\bBGProcessingTask(Request)?\b",
    "remote-notification": r"registerForRemoteNotifications|didReceiveRemoteNotification",
    "bluetooth-central": r"\bCBCentralManager\b",
    "bluetooth-peripheral": r"\bCBPeripheralManager\b",
    "external-accessory": r"\bEAAccessoryManager\b|\bEASession\b",
    "nearby-interaction": r"\bNISession\b",
    "push-to-talk": r"\bPTChannelManager\b",
}
# 2.5.1 (and the "unused entitlements" rejection): a capability the shipping
# entitlements grant must be one the app uses. Entitlement -> the API that uses it.
ENTITLEMENT_APIS = {
    "com.apple.developer.healthkit": r"\bHKHealthStore\b",
    "com.apple.developer.homekit": r"\bHMHomeManager\b",
    "com.apple.developer.icloud-container-identifiers": r"\bCKContainer\b|forUbiquityContainerIdentifier|NSUbiquitous",
    "com.apple.developer.ubiquity-kvstore-identifier": r"\bNSUbiquitousKeyValueStore\b",
    "com.apple.developer.nfc.readersession.formats": r"\bNFC(NDEF|Tag)?ReaderSession\b",
    "com.apple.developer.applesignin": r"\bASAuthorizationAppleIDProvider\b",
    "com.apple.developer.in-app-payments": r"\bPKPayment(Request|AuthorizationController|AuthorizationViewController)\b",
    "com.apple.developer.game-center": r"\bGKLocalPlayer\b",
    "com.apple.developer.usernotifications.time-sensitive": r"\.timeSensitive\b",
    "com.apple.developer.usernotifications.critical-alerts": r"\.criticalAlert\b|\.defaultCritical\b",
    "aps-environment": r"registerForRemoteNotifications",
    "com.apple.developer.push-to-talk": r"\bPTChannelManager\b",
    "com.apple.developer.weatherkit": r"\bWeatherService\b",
    "com.apple.developer.family-controls": r"\bAuthorizationCenter\b|\bFamilyActivityPicker\b",
    "com.apple.developer.devicecheck.appattest-environment": r"\bDCAppAttestService\b",
    "com.apple.developer.ClassKit-environment": r"\bCLSDataStore\b",
    "com.apple.security.application-groups": r"suiteName:|forSecurityApplicationGroupIdentifier",
}
# ATS keys that weaken App Transport Security and need a written reason in App
# Store Connect (NSAllowsArbitraryLoads itself is a blocker above).
ATS_EXCEPTION_KEYS = ("NSAllowsArbitraryLoadsInWebContent", "NSAllowsArbitraryLoadsForMedia",
                      "NSExceptionAllowsInsecureHTTPLoads", "NSTemporaryExceptionAllowsInsecureHTTPLoads",
                      "NSExceptionMinimumTLSVersion", "NSTemporaryExceptionMinimumTLSVersion")
# 2.3.7: keywords may not name other apps, companies or trademarks. The names a
# coding-agent app would be tempted to borrow.
KEYWORD_TRADEMARKS = re.compile(
    r"\b(ChatGPT|OpenAI|Claude|Anthropic|Codex|Copilot|GitHub|Cursor|Gemini|Google|Windsurf|Replit|Slack|"
    r"Discord|Termius|Blink|Warp|iTerm|Xcode|Apple|iPhone|iPad|Siri)\b|\b(chatgpt|openai|github|xcode|iphone|ipad)\b")
# The catalogue of common App Store rejections (public lists) mapped onto this
# app: each entry names the check here that catches it, or why none can.
COMMON_REJECTIONS_FILE = "cmux-next-ios/AppStoreReview/common-rejections.json"
COMMON_REJECTION_STATUSES = ("gated", "not-applicable", "follow-up", "not-deterministic")
METADATA_DIR = "cmux-next-ios/AppStoreReview/metadata"
SCREENSHOTS_DIR = "cmux-next-ios/AppStoreReview/screenshots/en-US"
HISTORY_FILE = "cmux-next-ios/AppStoreReview/rejection-history.json"
# The App Review notes App Store Connect gets (asc_review_package.py sync-notes).
REVIEW_NOTES = "cmux-next-ios/AppStoreReview/review-notes-asc.txt"
# cmux INTERNAL's record gets its own notes (asc_review_package.py --config
# TestFlight sync-notes): its build sells nothing, so they promise no purchase.
REVIEW_NOTES_BY_LANE = {"internal-submission": "cmux-next-ios/AppStoreReview/review-notes-asc-internal.txt"}
# The app's own list of bundles whose App Store record has no subscriptions
# (CmuxMobileBilling's BillingPurchaseAvailability): their plans screen is
# read-only, with no purchase, restore, manage or renewal-terms control.
APPS_WITHOUT_SUBSCRIPTIONS = re.compile(r"\bappsWithoutSubscriptions\s*:\s*Set<String>\s*=\s*\[([^\]]*)\]")
# Blockers the app already had when pushes and pull requests started failing on
# new ones; a fix removes its entry, and nothing is ever added to dodge a red.
KNOWN_BLOCKERS_FILE = "cmux-next-ios/AppStoreReview/known-blockers.json"
# The public App Store build: project.yml's AppStore configuration, bundle
# com.cmux.app (the record the classic app used; NEXT replaces it as an update).
APPSTORE_CONFIG = "AppStore"
APPSTORE_BUNDLE_ID = "com.cmux.app"
# Each lane's shipping configuration and the bundle its binary must carry: the
# appstore lane is the public app, the internal lane TestFlight's cmux INTERNAL.
# internal-submission is cmux INTERNAL's build judged as an App Store
# submission (Leo, 2026-11-22: "i NEED this shit on THE FUCKING APP STORE"):
# the TestFlight configuration and bundle, held to the appstore lane's
# strictness (configuration and bundle in project.yml, signed entitlements,
# the VPN API, asc validate). The ordinary internal lane stays as it was.
LANE_CONFIG = {"appstore": APPSTORE_CONFIG, "internal": "TestFlight", "internal-submission": "TestFlight"}
LANE_BUNDLE_ID = {"appstore": APPSTORE_BUNDLE_ID, "internal": "dev.cmux.app.internal",
                  "internal-submission": "dev.cmux.app.internal"}
# The lanes whose build goes to App Review: every check applies.
SUBMISSION_LANES = frozenset({"appstore", "internal-submission"})
LANES = ("appstore", "internal", "internal-submission")
# The App Store distribution configurations (AppStore, TestFlight,
# TestFlightStaging) sign with these; project.yml says so.
APPSTORE_ENTITLEMENTS = (
    "cmux-next-ios/App/CmuxMobileApp-TestFlight.entitlements",
    "cmux-next-ios/App/CmuxMobileApp-TestFlight-Group.entitlements",
    # The same sets with the universal links (CMUX_MOBILE_ASSOCIATED_DOMAINS=YES).
    "cmux-next-ios/App/CmuxMobileApp-TestFlight-Links.entitlements",
    "cmux-next-ios/App/CmuxMobileApp-TestFlight-Links-Group.entitlements",
)
UITEST_DIR = "cmux-next-ios/UITests"
STORE_RULES = "scripts/cmux-next/check-app-store-rules.py"


def apps_without_subscriptions(texts: dict[Path, str]) -> set[str]:
    """The bundle ids the app's sources list in appsWithoutSubscriptions."""
    return {bundle for text in texts.values() for match in APPS_WITHOUT_SUBSCRIPTIONS.finditer(text)
            for bundle in re.findall(r'"([\w.-]+)"', match.group(1))}


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
        # A build headed for App Review (appstore, internal-submission) gets every check.
        self.strict = lane in SUBMISSION_LANES
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

    def linked_package_dirs(self) -> list[Path]:
        """Every local Swift package the app links, transitively."""
        roots = [self.root / rel for rel in LINKED_PACKAGE_ROOTS]
        project = self.root / PROJECT_YML
        if project.is_file():
            for rel in PROJECT_PACKAGE_PATH_RE.findall(project.read_text(errors="ignore")):
                roots.append((self.root / APP_DIR / rel).resolve())
        seen: list[Path] = []
        queue = [r.resolve() for r in roots]
        while queue:
            pkg = queue.pop(0)
            if pkg in seen or not (pkg / "Package.swift").is_file():
                continue
            seen.append(pkg)
            text = (pkg / "Package.swift").read_text(errors="ignore")
            for rel in PACKAGE_PATH_RE.findall(text):
                queue.append((pkg / rel).resolve())
        return seen

    def linked_texts(self) -> dict[Path, str]:
        """The app's own folders plus every linked package's Sources."""
        out = dict(self.texts())
        dirs = [pkg / "Sources" for pkg in self.linked_package_dirs()]
        for path in self.swift_files(dirs):
            if path not in out:
                try:
                    out[path] = path.read_text(errors="ignore")
                except OSError:
                    continue
        return out

    def swift_files(self, dirs: Iterable[Path] | None = None) -> Iterable[Path]:
        bases = list(dirs) if dirs is not None else [self.root / rel for rel in IOS_SOURCE_DIRS]
        for base in bases:
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

    def metadata(self, report: bool = True) -> dict[str, dict]:
        """Every metadata JSON file; a file that does not parse is a finding
        when `report` (check_metadata reports it once; later readers skip it)."""
        out: dict[str, dict] = {}
        base = self.root / METADATA_DIR
        for path in sorted(base.rglob("*.json")):
            try:
                out[self.rel(path)] = json.loads(path.read_text())
            except (OSError, json.JSONDecodeError) as exc:
                if report:
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
        decoration = re.compile(r"(?i:\b(best|#1|number one|top[- ]rated|free)\b)|[\U0001F300-\U0001FAFF\u2600-\u27BF]")
        others_apps = re.compile(r"(?i:\b(ChatGPT|Claude|Codex|Copilot|Cursor|Gemini|Termius|Blink|iTerm|Warp|Apple|iPhone)\b)")
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
                if key in ("name", "subtitle") and decoration.search(value):
                    self.add("metadata.decoration", "2.3.7", "blocker",
                             f"{key} carries a ranking, price or emoji claim: {decoration.search(value).group(0)!r}", rel)
                if key == "keywords" and others_apps.search(value):
                    self.add("metadata.competitor-terms", "2.3.7", "blocker",
                             f"keywords name another app or trademark: {others_apps.search(value).group(0)!r}", rel)
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
        # App Store Connect asks for iPad screenshots only when the app runs
        # natively on iPad ("Required if app runs on iPad"). An iPhone-only app
        # (TARGETED_DEVICE_FAMILY "1") runs on iPad in compatibility mode with
        # no iPad screenshots listed, so the ipad folder is required only when
        # the app target's device families include 2 (iPad).
        families = ["iphone"]
        if "2" in app_device_families(self.root):
            families.append("ipad")
        for family in families:
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
        """A submission lane judges the build App Review gets: project.yml must
        define the lane's configuration with its bundle (appstore: AppStore,
        com.cmux.app; internal-submission: TestFlight, dev.cmux.app.internal)."""
        self.ran("appstore-config")
        name = LANE_CONFIG.get(self.lane, APPSTORE_CONFIG)
        want = LANE_BUNDLE_ID.get(self.lane, APPSTORE_BUNDLE_ID)
        text = (self.root / PROJECT_YML).read_text(errors="ignore")
        block = config_block(text, name)
        if not re.search(rf"^  {name}:\s*release\b", text, re.M) or block is None:
            self.add("appstore.config-missing", "2.1", "blocker",
                     f"{PROJECT_YML} has no {name} configuration, so there is no App Store build "
                     f"(bundle {want}) to judge", PROJECT_YML)
            return
        bundle = re.search(r"^\s*CMUX_MOBILE_APP_BUNDLE_ID:\s*\"?([\w.]+)", block, re.M)
        if not bundle or bundle.group(1) != want:
            self.add("appstore.bundle-id", "2.1", "blocker",
                     f"the {name} configuration's bundle is {bundle.group(1) if bundle else 'unset'!s}, "
                     f"not {want}", PROJECT_YML)

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

        # 3.1.1 / 3.1.2 / 2.1(b): what an app that sells subscriptions owes the reviewer.
        self.check_subscriptions(texts)

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
                    self.add("api.vpn-source", "2.5.1", "warning" if self.strict else "info",
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

        # 2.1 (completeness): a raw Swift error dump in user-facing text ("LinkError(code: ...)",
        # "The operation couldn't be completed. (... error 1.)"). Display sites use
        # UserFacingError.message(_:); logs and telemetry keep the raw error.
        raw_error = re.compile(r"\?\?\s*String\(describing:\s*error\)")
        log_line = re.compile(r"\blog\.|Log\.|Logger\(|privacy:|telemetry|detail:")
        for path, text in texts.items():
            for lineno, line in enumerate(text.splitlines(), 1):
                stripped = line.lstrip()
                if stripped.startswith("//") or not raw_error.search(line) or log_line.search(line):
                    continue
                self.add("ux.raw-error", "2.1", "warning",
                         "an error shown as String(describing:) reads as a Swift dump; use UserFacingError.message(_:)",
                         f"{self.rel(path)}:{lineno}")

        self.check_ai_and_copy(texts, joined)

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

    def check_ai_and_copy(self, texts: dict[Path, str], joined: str) -> None:
        """Classes mapped from the public rejection lists (hq docs/handbook/app-review-rejections.md,
        "Public rejection lists mapped"): third-party AI consent, reporting AI or user content,
        unfinished copy, IPv4-only name lookups and permission pre-prompts."""
        # 5.1.2(i) (2025-11): personal data goes to a third-party AI only after the app names the
        # provider and the person agrees. Chief's replies come from third-party models (cmux
        # Cloud, or the Mac's), and Chief calls go to OpenAI.
        ai = re.search(r"\bChiefSession\b|\bChiefCloudBackend\b|api\.openai\.com|api\.anthropic\.com", joined)
        if ai:
            if not re.search(r"aiSharingConsent", joined):
                self.add("ai.consent", "5.1.2(i)", "blocker",
                         "the app sends messages to third-party AI models with no consent asked first "
                         "(ChiefAIConsent: name the providers, Agree before the first send, a way to withdraw)", APP_DIR)
            elif not re.search(r"defaultValue: \"[^\"\n]*Anthropic[^\"\n]*OpenAI", joined):
                self.add("ai.consent", "5.1.2(i)", "blocker",
                         "the AI sharing question does not name the providers (Anthropic, OpenAI)", APP_DIR)
            elif not re.search(r"\.sendGate\s*=\s*\{[^}]*ChiefAIConsent\.isGranted", joined):
                # The Send button is one of several send paths (Return, the effect picker, voice,
                # polls, Send Now); the conversation's sendGate sees them all.
                self.add("ai.consent", "5.1.2(i)", "blocker",
                         "the AI sharing question is not asked on every send path "
                         "(set ConversationViewController.sendGate to check ChiefAIConsent.isGranted)", APP_DIR)
            # 1.2 / 4.7.1: chatbots and user-generated content need a way to report content.
            if not re.search(r"ChiefReport\.open\(", joined):
                self.add("ugc.report", "1.2", "blocker",
                         "no way to report an AI reply or a message (ChiefReport in Chief's menu and info page)", APP_DIR)
        # 2.1 / 2.3.1: user-facing copy that says a feature is unfinished.
        unfinished = re.compile(r"(?:Text\(|Label\(|Button\(|defaultValue: )\"[^\"\n]*"
                                r"(?i:still in progress|coming soon|not yet implemented|under construction|work in progress)")
        # 2.5.5: App Review runs on an IPv6-only network; IPv4-only lookups fail there.
        ipv4_only = re.compile(r"\b(gethostbyname|inet_addr)\(|\"https?://\d{1,3}(?:\.\d{1,3}){3}[:/\"]")
        # 5.1.1(iv): a pre-permission screen whose button says Allow reads as forcing consent.
        pre_prompt = re.compile(r"Button\(\"Allow(?: [A-Z][a-z]+)?\"")
        for path, text in texts.items():
            for lineno, line in enumerate(text.splitlines(), 1):
                if line.lstrip().startswith("//"):
                    continue
                if unfinished.search(line):
                    self.add("copy.unfinished", "2.1", "blocker",
                             "user-facing copy says the feature is unfinished; ship it finished or leave it out",
                             f"{self.rel(path)}:{lineno}")
                if ipv4_only.search(line):
                    self.add("net.ipv4-only", "2.5.5", "warning",
                             "an IPv4-only lookup or address; App Review's network is IPv6-only (NAT64)",
                             f"{self.rel(path)}:{lineno}")
                if pre_prompt.search(line):
                    self.add("privacy.pre-prompt", "5.1.1(iv)", "warning",
                             "a button titled Allow before a permission prompt; let the system prompt ask",
                             f"{self.rel(path)}:{lineno}")

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

    def check_subscriptions(self, texts: dict[Path, str]) -> None:
        """An app that sells through StoreKit must let a user restore (3.1.1),
        show the renewal terms with Terms of Use and Privacy Policy links where
        it sells (3.1.2), link its Terms in the store listing (3.1.2), and tell
        the reviewer where the plans are (2.1(b): on 2026-11-07 App Review
        could not locate the in-app purchases). Nothing applies to an app
        without StoreKit."""
        storekit = [path for path, text in texts.items()
                    if re.search(r"^\s*import StoreKit\b", text, re.M)]
        if not storekit:
            return
        self.ran("subscriptions")
        notes_rel = REVIEW_NOTES_BY_LANE.get(self.lane, REVIEW_NOTES)
        notes_path = self.root / notes_rel
        notes = notes_path.read_text(errors="ignore") if notes_path.is_file() else ""
        notes = "\n".join(line for line in notes.splitlines() if not line.startswith("##"))
        bundle = LANE_BUNDLE_ID.get(self.lane, APPSTORE_BUNDLE_ID)
        if self.strict and bundle in apps_without_subscriptions(texts):
            # The app itself offers no purchase in this bundle, so the reviewer
            # must not be sent looking for one (2.1): the notes name the "Plan"
            # row and promise no Subscribe, Restore Purchases, Manage
            # Subscription or Sandbox purchase, and the selling rules do not apply.
            promised = sorted(set(re.findall(r'"Subscribe"|"Restore Purchases"|"Manage Subscription"|\bSandbox\b', notes)))
            problems = [f"promises {', '.join(promised)}"] if promised else []
            if '"Plan"' not in notes:
                problems.append('never names "Plan"')
            if problems:
                self.add("iap.review-notes", "2.1(b)", "blocker",
                         f"the review notes ({notes_rel}) {'; '.join(problems)}, but {bundle} offers no purchase "
                         "(appsWithoutSubscriptions): Settings > \"Plan\" shows the current plan read-only", notes_rel)
            return
        joined = "\n".join(texts.values())
        where = self.rel(storekit[0])
        if not re.search(r"\"Restore Purchases\"", joined) or not re.search(r"\bAppStore\.sync\(\)", joined):
            self.add("iap.restore", "3.1.1", "blocker",
                     "the app sells through StoreKit but has no \"Restore Purchases\" control that runs AppStore.sync()", where)
        missing = [label for label, pattern in (
            ("the auto-renewal terms", r"renew automatically|auto-renew"),
            ("a Terms of Use link", r"cmux\.com/terms-of-service"),
            ("a Privacy Policy link", r"cmux\.com/privacy-policy"),
        ) if not re.search(pattern, joined)]
        if missing:
            self.add("iap.disclosure", "3.1.2", "blocker",
                     f"the app sells subscriptions but its sources lack {', '.join(missing)}", where)
        if not re.search(r"manageSubscriptionsSheet|showManageSubscriptions", joined):
            self.add("iap.manage", "3.1.2", "warning",
                     "no in-app way to manage the subscription (manageSubscriptionsSheet)", where)
        descriptions = [body.get("description", "") for body in self.metadata(report=False).values() if isinstance(body, dict)]
        if descriptions and not any(re.search(r"terms-of-service|/terms\b|EULA", d, re.I) for d in descriptions):
            self.add("metadata.subscription-terms", "3.1.2", "blocker",
                     "the app sells subscriptions but no store description links its Terms of Use (EULA)", METADATA_DIR)
        problems = []
        if re.search(r"sells? (no|nothing)|no (digital goods|in-app purchases?)|no StoreKit", notes, re.I):
            problems.append("says the app sells nothing")
        for label in ('"Plan"', '"Restore Purchases"', '"Manage Subscription"'):
            if label not in notes:
                problems.append(f"never names {label}")
        if not re.search(r"Sandbox", notes):
            problems.append("does not say purchases are made in the Sandbox")
        if problems:
            self.add("iap.review-notes", "2.1(b)", "blocker",
                     f"the review notes ({notes_rel}) {'; '.join(problems)}: the reviewer must find the subscriptions "
                     "(Settings > \"Plan\") and Restore Purchases", notes_rel)

    def check_apple_sign_in_ships(self) -> None:
        """Debug builds hide the Apple button (CMUX_MOBILE_APPLE_SIGN_IN = NO);
        this lane's shipping configuration (AppStore, or TestFlight for the
        internal lane) must turn it on and sign with entitlements that carry
        Sign in with Apple, or the shipped app offers Google and GitHub without
        Apple (4.8). Another configuration turning it on proves nothing."""
        self.ran("signin-apple-shipping")
        name = LANE_CONFIG.get(self.lane, APPSTORE_CONFIG)
        project = self.root / PROJECT_YML
        text = project.read_text(errors="ignore") if project.is_file() else ""
        blocks = config_blocks(text, name)
        # The last value set for this configuration wins (the target's over the project's).
        values = [m.group(1) for b in blocks for m in re.finditer(r"^\s*CMUX_MOBILE_APPLE_SIGN_IN:\s*\"?(\w+)", b, re.M)]
        if not values or values[-1] != "YES":
            self.add("signin.apple-shipping", "4.8", "blocker",
                     f"the {name} configuration does not set CMUX_MOBILE_APPLE_SIGN_IN to YES, so the shipped app "
                     "hides Sign in with Apple", PROJECT_YML)
        ents = [rel for b in blocks
                for m in re.finditer(r"^\s*CMUX_MOBILE_ENTITLEMENTS_(?:NO|YES):\s*\"?([^\s\"]+)", b, re.M)
                for rel in entitlement_files(text, m.group(1))]
        if not ents:
            self.add("signin.apple-entitlement", "4.8", "blocker",
                     f"the {name} configuration names no entitlements file, so nothing shows it carries Sign in with Apple",
                     PROJECT_YML)
        for rel in dict.fromkeys(ents):
            path = self.root / APP_DIR / rel
            where = f"{APP_DIR}/{rel}"
            if not path.is_file():
                self.add("signin.apple-entitlement", "4.8", "blocker",
                         f"the {name} configuration signs with {where}, which does not exist", where)
                continue
            try:
                body = plistlib.loads(path.read_bytes())
            except plistlib.InvalidFileException:
                body = {}
            if "com.apple.developer.applesignin" not in body:
                self.add("signin.apple-entitlement", "4.8", "blocker",
                         f"{where} ({name}) lacks com.apple.developer.applesignin", where)

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
            "NSFaceIDUsageDescription": (r"LAContext|evaluatePolicy\(\.deviceOwnerAuthentication|\.biometry(Any|CurrentSet)\b|kSecAccessControlBiometry", "Face ID"),
            "NSUserTrackingUsageDescription": (r"ATTrackingManager", "tracking"),
            "NSLocalNetworkUsageDescription": (r"NWBrowser|NWListener|NetServiceBrowser|_udp|Bonjour", "local network"),
        }
        linked = self.linked_texts()
        joined = "\n".join(linked.values())
        for key, (pattern, label) in usage.items():
            uses = re.search(pattern, joined) is not None
            value = plist.get(key)
            if uses and not value:
                self.add("privacy.purpose-string", "5.1.1", "blocker",
                         f"the app uses the {label} API but {key} is missing", where)
            elif value and (len(value) < 25 or re.fullmatch(r"(?i).*\b(needs?|requires?|wants?) (to )?(access|permission|use)\b.*", value)
                            or re.fullmatch(r"(?i)\s*(this app|the app|cmux) (uses|accesses|would like)\b.*", value)):
                self.add("privacy.purpose-string-vague", "5.1.1", "warning",
                         f"{key} is too generic for App Review: {value!r}", where)
        # NSBonjourServices lists the service types the app browses or
        # advertises; dialing a LAN address (or a localhost NWListener) needs
        # only the purpose string, so the key is asked for only when Bonjour is.
        bonjour = re.search(r"NWBrowser|NetServiceBrowser|NetService\(|NWListener\.Service|\.bonjour(WithTXTRecord)?\(", joined)
        if bonjour and not plist.get("NSBonjourServices"):
            self.add("privacy.bonjour", "5.1.1", "blocker",
                     "the app browses or advertises Bonjour services but NSBonjourServices is missing", where)
        if "ITSAppUsesNonExemptEncryption" not in plist:
            self.add("export.encryption", "2.1", "warning", "ITSAppUsesNonExemptEncryption is not declared", where)
        ats = plist.get("NSAppTransportSecurity") or {}
        if ats.get("NSAllowsArbitraryLoads"):
            self.add("ats.arbitrary-loads", "2.5.1", "blocker", "NSAllowsArbitraryLoads is true; App Review asks for a justification", where)
        if plist.get("UIRequiredDeviceCapabilities") and "ipad" not in json.dumps(plist).lower():
            pass
        # 2.5.1: every ATS exception needs a written reason in App Store Connect.
        weakened = sorted({key for key in ATS_EXCEPTION_KEYS if key in json.dumps(ats)})
        if weakened:
            self.add("ats.exception", "2.5.1", "warning",
                     f"App Transport Security is weakened ({', '.join(weakened)}); give App Review the reason", where)

    def check_privacy_manifests(self) -> None:
        """Each bundle's manifest declares every required-reason API its sources use."""
        self.ran("privacy-manifest")
        texts = self.texts()
        # The app's manifest covers every package the app links statically, not only its own folders.
        linked = self.linked_texts()
        for rel, scope in PRIVACY_MANIFESTS.items():
            path = self.root / rel
            if not path.is_file():
                self.add("privacy.manifest", "5.1.2", "blocker", "no privacy manifest for this bundle", rel)
                continue
            try:
                manifest = plistlib.loads(path.read_bytes())
            except (OSError, plistlib.InvalidFileException) as exc:
                self.add("privacy.manifest", "5.1.2", "blocker", f"the privacy manifest does not parse: {exc}", rel)
                continue
            declared = {entry.get("NSPrivacyAccessedAPIType"): entry.get("NSPrivacyAccessedAPITypeReasons") or []
                        for entry in manifest.get("NSPrivacyAccessedAPITypes") or []}
            for category, reasons in declared.items():
                if not reasons:
                    self.add("privacy.manifest-reason", "5.1.2", "blocker", f"{category} has no reason code", rel)
                valid = REQUIRED_REASON_CODES.get(category)
                if valid is None:
                    self.add("privacy.manifest-reason-code", "5.1.2", "blocker",
                             f"{category} is not a required-reason API category (ITMS-91056)", rel)
                    continue
                for code in reasons:
                    if code not in valid:
                        self.add("privacy.manifest-reason-code", "5.1.2", "blocker",
                                 f"{code} is not a reason Apple accepts for {category} (ITMS-91056)", rel)
                    elif code in SDK_ONLY_REASON_CODES:
                        self.add("privacy.manifest-reason-code", "5.1.2", "blocker",
                                 f"{code} is for third-party SDKs only, never an app's own bundle", rel)
            self.check_collected_data(manifest, rel)
            sources = {p: t for p, t in (linked if scope is None else texts).items()
                       if scope is None or self.rel(p).startswith(scope + "/")}
            shared = next(((p, m) for p, t in sources.items() for m in [APP_GROUP_DEFAULTS.search(t)] if m), None)
            if shared and APP_GROUP_DEFAULTS_REASON not in declared.get("NSPrivacyAccessedAPICategoryUserDefaults", []):
                source, match = shared
                lineno = sources[source].count("\n", 0, match.start()) + 1
                self.add("privacy.reason-app-group", "5.1.2", "blocker",
                         f"{match.group(0)} reads or writes App Group defaults, which needs the UserDefaults reason "
                         f"{APP_GROUP_DEFAULTS_REASON} (CA92.1 covers only the app's own defaults)",
                         f"{self.rel(source)}:{lineno} -> {rel}")
            for category, pattern in REQUIRED_REASON_APIS.items():
                if category in declared:
                    continue
                for source, text in sources.items():
                    match = re.search(pattern, text)
                    if match:
                        lineno = text.count("\n", 0, match.start()) + 1
                        self.add("privacy.required-reason", "5.1.2", "blocker",
                                 f"{match.group(0)} is a required-reason API ({category}) the manifest does not declare "
                                 "(ITMS-91053)", f"{self.rel(source)}:{lineno} -> {rel}")
                        break

    def check_collected_data(self, manifest: dict, rel: str) -> None:
        """ITMS-91056 and 5.1.2: the collected data types and purposes are
        Apple's identifiers, and declared tracking names its domains and asks
        through App Tracking Transparency."""
        tracking_types = []
        for entry in manifest.get("NSPrivacyCollectedDataTypes") or []:
            kind = entry.get("NSPrivacyCollectedDataType")
            if kind not in COLLECTED_DATA_TYPES:
                self.add("privacy.collected-data", "5.1.2", "blocker",
                         f"{kind!r} is not a collected data type Apple accepts (ITMS-91056)", rel)
            for purpose in entry.get("NSPrivacyCollectedDataTypePurposes") or []:
                if purpose not in COLLECTED_DATA_PURPOSES:
                    self.add("privacy.collected-data", "5.1.2", "blocker",
                             f"{purpose!r} is not a collection purpose Apple accepts (ITMS-91056)", rel)
            if entry.get("NSPrivacyCollectedDataTypeTracking") is True:
                tracking_types.append(kind)
        if manifest.get("NSPrivacyTracking") is True or tracking_types:
            if manifest.get("NSPrivacyTracking") is True and not manifest.get("NSPrivacyTrackingDomains"):
                self.add("privacy.tracking", "5.1.2", "blocker",
                         "NSPrivacyTracking is true but NSPrivacyTrackingDomains is empty", rel)
            joined = "\n".join(self.linked_texts().values())
            if not re.search(r"\bATTrackingManager\b", joined):
                self.add("privacy.tracking", "5.1.2", "blocker",
                         "the manifest declares tracking but the app never asks through App Tracking Transparency "
                         "(ATTrackingManager)", rel)

    def check_entitlements_used(self, ents: dict, where: str) -> None:
        """Every capability the shipping entitlements grant is one the app uses
        (an unused HealthKit, iCloud or Apple Pay capability is a rejection)."""
        self.ran("entitlements-used")
        joined = "\n".join(self.linked_texts().values())
        for key, pattern in ENTITLEMENT_APIS.items():
            if key in ents and not re.search(pattern, joined):
                self.add("entitlement.unused", "2.5.1", "blocker",
                         f"{key} is granted but no source the app links uses it ({pattern})", where)

    def check_common_rejection_rules(self, plist: dict) -> None:
        """The common rejections (common-rejections.json) a source tree can
        prove: background modes in use, no UIWebView, an in-app privacy policy
        link, sign-in steps in the review notes, keywords without other
        companies' names, and a listing that sells nothing the build lacks."""
        self.ran("common-rejection-rules")
        texts = self.linked_texts()
        joined = "\n".join(texts.values())
        # 2.5.4: every background mode is used for its purpose.
        for mode in plist.get("UIBackgroundModes") or []:
            pattern = BACKGROUND_MODE_APIS.get(mode)
            if pattern and not re.search(pattern, joined):
                self.add("background.unused-mode", "2.5.4", "blocker",
                         f"UIBackgroundModes declares {mode!r} but no source the app links uses it ({pattern})",
                         PROJECT_YML)
        # ITMS-90809 / 2.5.1: UIWebView is no longer accepted.
        for path, text in texts.items():
            for lineno, line in enumerate(text.splitlines(), 1):
                if re.search(r"\bUIWebView\b", line) and not line.lstrip().startswith("//"):
                    self.add("api.uiwebview", "2.5.1", "blocker",
                             "UIWebView is deprecated and App Store Connect refuses it (ITMS-90809); use WKWebView",
                             f"{self.rel(path)}:{lineno}")
        meta = self.metadata(report=False)
        # 5.1.1(i): the privacy policy is reachable inside the app, not only in the listing.
        privacy = {body.get("privacyPolicyUrl") for body in meta.values() if isinstance(body, dict)} - {None, ""}
        if privacy and not any(url in joined for url in privacy):
            self.add("privacy.policy-in-app", "5.1.1(i)", "blocker",
                     f"no source the app links opens the privacy policy ({', '.join(sorted(privacy))})", APP_DIR)
        # 2.3.7: keywords name no other app, company or trademark.
        for rel, body in meta.items():
            keywords = body.get("keywords") if isinstance(body, dict) else None
            if isinstance(keywords, str):
                for match in KEYWORD_TRADEMARKS.finditer(keywords):
                    self.add("metadata.keyword-trademark", "2.3.7", "blocker",
                             f"keywords name {match.group(0)!r}, another company's name or trademark", rel)
        # 2.3.1: a build that sells nothing has no listing that says it sells in the app.
        bundle = LANE_BUNDLE_ID.get(self.lane)
        if self.strict and bundle in apps_without_subscriptions(texts):
            claim = re.compile(r"(?i)\b(bought|buy|purchase[ds]?|subscribe)\b[^.]{0,40}\bin (the )?app\b|\bin-app purchase")
            for rel, body in meta.items():
                description = body.get("description") if isinstance(body, dict) else None
                if isinstance(description, str) and rel.endswith("en-US.json") and claim.search(description):
                    self.add("metadata.iap-claim", "2.3.1", "warning",
                             f"{bundle} sells nothing in the app, but the store description says "
                             f"{claim.search(description).group(0)!r}", rel)
        # 2.1: the reviewer gets sign-in steps (a demo account) in the notes.
        if self.strict:
            notes_rel = REVIEW_NOTES_BY_LANE.get(self.lane, REVIEW_NOTES)
            notes = self.root / notes_rel
            text = notes.read_text(errors="ignore") if notes.is_file() else ""
            if not re.search(r"\{\{DEMO_ACCOUNT_[A-Z_]+\}\}|(?i:demo account)", text):
                self.add("review-notes.sign-in", "2.1", "blocker",
                         "the App Review notes give no demo account or sign-in steps", notes_rel)

    def check_common_rejections(self) -> list[dict]:
        """Every entry of the common-rejections mapping is either gated by a
        detector that exists, or says why it is not (with a follow-up)."""
        self.ran("common-rejections")
        path = self.root / COMMON_REJECTIONS_FILE
        if not path.is_file():
            return []
        try:
            entries = json.loads(path.read_text()).get("rejections", [])
        except (OSError, json.JSONDecodeError) as exc:
            self.add("common-rejections.parse", "-", "blocker", f"the mapping does not parse: {exc}", COMMON_REJECTIONS_FILE)
            return []
        tests_text = "\n".join(p.read_text(errors="ignore") for p in (self.root / UITEST_DIR).glob("*.swift"))
        script_text = Path(__file__).read_text()
        rules_path = self.root / STORE_RULES
        rules_text = rules_path.read_text(errors="ignore") if rules_path.is_file() else ""
        workflows = "\n".join(p.read_text(errors="ignore") for p in (self.root / ".github/workflows").glob("ios-*.yml"))
        for entry in entries:
            name = f"{entry.get('id')} ({entry.get('guideline')})"
            status = entry.get("status")
            if status not in COMMON_REJECTION_STATUSES:
                self.add("common-rejections.status", entry.get("guideline", "-"), "blocker",
                         f"{name} has status {status!r}, not one of {', '.join(COMMON_REJECTION_STATUSES)}",
                         COMMON_REJECTIONS_FILE)
            if not entry.get("sources"):
                self.add("common-rejections.source", entry.get("guideline", "-"), "blocker",
                         f"{name} names no public source", COMMON_REJECTIONS_FILE)
            detectors = entry.get("detectors") or []
            if status == "gated" and not detectors:
                self.add("common-rejections.no-detector", entry.get("guideline", "-"), "blocker",
                         f"{name} is gated but names no detector", COMMON_REJECTIONS_FILE)
            if status == "follow-up" and not entry.get("follow_up"):
                self.add("common-rejections.no-follow-up", entry.get("guideline", "-"), "blocker",
                         f"{name} is a follow-up but says nothing about what is left", COMMON_REJECTIONS_FILE)
            for detector in detectors:
                kind, _, ref = detector.partition(":")
                present = {
                    "lint": f'"{ref}"' in script_text,
                    "store-rule": f'"{ref}"' in rules_text,
                    "uitest": f"func {ref}(" in tests_text,
                    "workflow": ref in workflows,
                }.get(kind, False)
                if not present:
                    self.add("common-rejections.detector-missing", entry.get("guideline", "-"), "blocker",
                             f"{name} names detector {detector}, which does not exist", COMMON_REJECTIONS_FILE)
        return entries

    def check_entitlements(self, ents: dict, where: str) -> None:
        self.ran("entitlements")
        if self.strict:
            for key in ents:
                if key.startswith("com.apple.developer.networking.networkextension") or key.startswith("com.apple.developer.networking.vpn"):
                    self.add("entitlement.vpn", "2.5.1", "blocker",
                             f"the App Store binary carries {key}; the system VPN API was rejected before", where)
            if ents.get("get-task-allow") is True:
                self.add("entitlement.debug", "2.1", "blocker", "get-task-allow is true (a debug-signed build)", where)
            if ents.get("aps-environment") not in (None, "production"):
                self.add("entitlement.aps", "2.1", "blocker", f"aps-environment is {ents.get('aps-environment')!r}, not production", where)

    # ---------------------------------------------------------------- binary

    def check_app_bundle(self, app: Path, expect_commit: str = "") -> None:
        self.ran("binary")
        info_path = app / "Info.plist"
        if not info_path.is_file():
            self.add("binary.info-plist", "2.1", "blocker", "the bundle has no Info.plist", str(app))
            return
        info = plistlib.loads(info_path.read_bytes())
        # The binary must be this lane's app, built from the judged commit:
        # a stale or internal artifact is never this build's verdict.
        want_bundle = LANE_BUNDLE_ID.get(self.lane)
        if want_bundle and info.get("CFBundleIdentifier") != want_bundle:
            self.add("binary.bundle-id", "2.1", "blocker",
                     f"the binary's CFBundleIdentifier is {info.get('CFBundleIdentifier')!r}, not {want_bundle}: "
                     "it is not this lane's app", f"{app.name}/Info.plist")
        if expect_commit:
            built = str(info.get("CmuxMobileSourceCommit") or "")
            if not built or built != expect_commit:
                self.add("binary.source-commit", "2.1", "blocker",
                         f"the binary was built from {built or 'an unrecorded commit'}, not {expect_commit}: "
                         "it is not the build being judged", f"{app.name}/Info.plist")
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
            if not (appex / "PrivacyInfo.xcprivacy").is_file():
                self.add("privacy.manifest", "5.1.2", "blocker",
                         "the extension has no PrivacyInfo.xcprivacy (it links required-reason APIs)", appex.name)
            try:
                ext = plistlib.loads((appex / "Info.plist").read_bytes())
            except (OSError, plistlib.InvalidFileException):
                continue
            point = (ext.get("NSExtension") or {}).get("NSExtensionPointIdentifier", "")
            if self.strict and point.startswith("com.apple.networkextension"):
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
            b"_OBJC_CLASS_$_UIWebView": ("api.uiwebview", "2.5.1", "blocker", "links UIWebView (ITMS-90809)"),
        }
        for exe in executables:
            if not exe.is_file():
                continue
            data = exe.read_bytes()
            for needle, (rule, guideline, severity, label) in needles.items():
                if needle in data:
                    if rule == "api.vpn" and not self.strict:
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


FETCH_HEADERS = {
    "User-Agent": "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
    "Accept": "text/html,*/*",
}
MAX_REDIRECTS = 5


class UnsafeURL(Exception):
    """A URL the lint must not fetch: not https, or a host that is not public."""


def public_address(host: str, port: int) -> str:
    """The one address `host` is fetched from: every address it resolves to must
    be public (global), so a URL in the judged source can never reach the
    runner's loopback, link-local metadata service or a private network. The
    connection goes to this address, so a second lookup cannot swap it."""
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except OSError as exc:
        raise UnsafeURL(f"{host} does not resolve ({exc})") from exc
    addrs = [info[4][0] for info in infos]
    if not addrs:
        raise UnsafeURL(f"{host} does not resolve")
    for addr in addrs:
        ip = ipaddress.ip_address(addr.split("%", 1)[0])
        if not ip.is_global or ip.is_multicast:
            raise UnsafeURL(f"{host} resolves to {ip}, which is not a public address")
    return addrs[0]


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS to one already-checked address, the certificate verified for the host name."""

    def __init__(self, host: str, address: str, port: int, timeout: float) -> None:
        super().__init__(host, port, timeout=timeout, context=ssl.create_default_context())
        self.pinned_address = address

    def connect(self) -> None:
        sock = socket.create_connection((self.pinned_address, self.port), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def safe_get(url: str, timeout: float = 25) -> tuple[int, str, str]:
    """GET an https URL on a public host, following at most MAX_REDIRECTS
    redirects, each checked the same way. Returns (status, final URL, body)."""
    for _ in range(MAX_REDIRECTS + 1):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme != "https" or not parts.hostname:
            raise UnsafeURL(f"{url} is not an https URL")
        port = parts.port or 443
        address = public_address(parts.hostname, port)
        conn = PinnedHTTPSConnection(parts.hostname, address, port, timeout)
        try:
            path = urllib.parse.urlunsplit(("", "", parts.path or "/", parts.query, ""))
            conn.request("GET", path, headers=FETCH_HEADERS)
            resp = conn.getresponse()
            status = resp.status
            location = resp.getheader("Location")
            body = resp.read(2_000_000).decode("utf-8", "ignore")
        finally:
            conn.close()
        if status in (301, 302, 303, 307, 308) and location:
            url = urllib.parse.urljoin(url, location)
            continue
        return status, url, body
    raise UnsafeURL(f"more than {MAX_REDIRECTS} redirects")


def fetch(url: str) -> dict:
    try:
        status, final, body = safe_get(url)
    except UnsafeURL as exc:
        return {"url": url, "status": 0, "final_url": url, "title": "", "error": f"not fetched: {exc}"}
    except Exception as exc:  # noqa: BLE001 - network errors are findings
        return {"url": url, "status": 0, "final_url": url, "title": "", "error": f"{type(exc).__name__}: {exc}"}
    if status >= 400:
        return {"url": url, "status": status, "final_url": final, "title": "", "error": f"HTTP {status}"}
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


# xcodegen's iOS preset (and Xcode's) is TARGETED_DEVICE_FAMILY "1,2": an app
# that never sets it runs natively on iPhone and iPad.
DEFAULT_DEVICE_FAMILIES = frozenset({"1", "2"})
DEVICE_FAMILY_RE = re.compile(r'^\s*"?TARGETED_DEVICE_FAMILY"?:\s*"?([0-9 ,]*)"?\s*(?:#.*)?$', re.M)
APP_TARGET = "CmuxMobileApp"
# Configurations no App Store build uses, whose device families the gate ignores.
NON_SHIPPING_CONFIGS = frozenset({"Debug:"})


def app_device_families(root: Path, target: str = APP_TARGET) -> frozenset[str]:
    """The device families (1 iPhone, 2 iPad) project.yml builds the app
    target for: every TARGETED_DEVICE_FAMILY in that target's block, else the
    project's own settings, else xcodegen's iOS default "1,2"."""
    project = root / PROJECT_YML
    if not project.is_file():
        return DEFAULT_DEVICE_FAMILIES
    lines = project.read_text(errors="ignore").splitlines()
    in_target: list[str] = []
    outside: list[str] = []
    in_targets = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip() and not line[0].isspace():
            in_targets = line.rstrip() == "targets:"
        if in_targets and line.rstrip() == f"  {target}:":
            i += 1
            while i < len(lines) and (not lines[i].strip() or lines[i].startswith("   ")):
                in_target.append(lines[i])
                i += 1
            continue
        if not in_targets:
            outside.append(line)
        i += 1

    def shipped(block: list[str]) -> list[str]:
        """The block without its Debug config: Debug builds also run on an
        iPad mini simulator (an unfolded foldable's stand-in), and no Debug
        build reaches App Review."""
        kept: list[str] = []
        skip_deeper: int | None = None
        for line in block:
            indent = len(line) - len(line.lstrip())
            if skip_deeper is not None:
                if not line.strip() or indent > skip_deeper:
                    continue
                skip_deeper = None
            if line.strip() in NON_SHIPPING_CONFIGS:
                skip_deeper = indent
                continue
            kept.append(line)
        return kept

    def families(block: list[str]) -> set[str]:
        found: set[str] = set()
        for value in DEVICE_FAMILY_RE.findall("\n".join(shipped(block))):
            found |= {part.strip() for part in value.split(",") if part.strip()}
        return found

    return frozenset(families(in_target) or families(outside) or DEFAULT_DEVICE_FAMILIES)


def entitlement_files(text: str, value: str) -> list[str]:
    """The entitlements files a CMUX_MOBILE_ENTITLEMENTS_* value can sign with:
    the path itself, or for a switch such as
    `$(CMUX_MOBILE_DISTRIBUTION_ENTITLEMENTS_$(CMUX_MOBILE_ASSOCIATED_DOMAINS))`
    every `<prefix>_NO` / `<prefix>_YES` path project.yml sets, since the build
    may pick either. A reference that resolves to nothing yields nothing."""
    switch = re.fullmatch(r"\$\((\w+)_\$\(\w+\)\)", value)
    if not switch:
        return [value] if re.fullmatch(r"[\w./-]+", value) else []
    prefix = re.escape(switch.group(1))
    return [m.group(1) for m in re.finditer(rf"^\s*{prefix}_(?:NO|YES):\s*\"?([\w./-]+)", text, re.M)]


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


def config_blocks(text: str, name: str) -> list[str]:
    """Every `configs: NAME:` block in project.yml (the project's at indent 4,
    each target's at indent 8), in file order."""
    lines = text.splitlines()
    out: list[str] = []
    for i, line in enumerate(lines):
        indent = len(line) - len(line.lstrip())
        if line.strip() != f"{name}:" or indent not in (4, 8):
            continue
        block = []
        for follow in lines[i + 1:]:
            if follow.strip() and len(follow) - len(follow.lstrip()) <= indent:
                break
            block.append(follow)
        out.append("\n".join(block))
    return out


def marketing_version(root: Path, lane: str) -> str:
    """The version App Store Connect holds for this lane: a submission lane's
    configuration's own MARKETING_VERSION (AppStore for appstore, TestFlight
    for internal-submission) when it sets one, else the base one."""
    text = (root / PROJECT_YML).read_text(errors="ignore")
    pattern = re.compile(r"^\s*MARKETING_VERSION:\s*\"?([0-9][0-9.]*)", re.M)
    if lane in SUBMISSION_LANES:
        block = config_block(text, LANE_CONFIG[lane])
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
        if lint.strict:
            lint.check_appstore_config()
        urls += lint.check_sources()
        lint.check_info_plist(lint.project_info(), PROJECT_YML)
        lint.check_privacy_manifests()
        lint.check_store_rules()
        lint.check_common_rejection_rules(lint.project_info())
        for rel in APPSTORE_ENTITLEMENTS:
            if lint.strict and (root / rel).is_file():
                ents = plistlib.loads((root / rel).read_bytes())
                lint.check_entitlements(ents, rel)
                lint.check_entitlements_used(ents, rel)
    app = None
    if args.ipa:
        app = unpack_ipa(Path(args.ipa))
    elif args.app:
        app = Path(args.app)
    if app:
        lint.check_app_bundle(app, args.expect_commit or "")
    url_results = lint.check_urls(urls) if args.check_urls else []
    history = lint.check_history()
    common = lint.check_common_rejections()
    result = {
        "lane": args.lane,
        "binary": str(app) if app else None,
        "checked": sorted(set(lint.checked)),
        "findings": [f.as_dict() for f in lint.findings],
        "urls": url_results,
        "history": history,
        "common_rejections": {status: sum(1 for e in common if e.get("status") == status)
                              for status in COMMON_REJECTION_STATUSES},
    }
    if args.json:
        Path(args.json).write_text(json.dumps(result, indent=2))
    md = render([dict(f, source="lint") for f in result["findings"]], result, None, [])
    print(md)
    return 1 if any(f.severity == "blocker" for f in lint.findings) else 0


# ------------------------------------------------------------------ report

def asc_findings(path: Path) -> list[dict]:
    """`asc validate --output json`: every check that is blocking (or any
    warning under --strict) is a blocker for us; Apple's own tool says so,
    except asc's advice (ASC_ADVISORY) and, on a version Apple already has,
    its state and its locked listing text (SUBMITTED_STATES)."""
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
    submitted_state = ""
    for c in checks:
        code = str(c.get("code") or c.get("id") or c.get("checkId") or c.get("check") or "")
        state = re.search(r'non-editable state "?([A-Z_]+)', str(c.get("message") or "")) if code == ASC_EDITABLE else None
        if state and state.group(1) in SUBMITTED_STATES:
            submitted_state = state.group(1)
    out = []
    seen: set[tuple[str, str, str]] = set()
    for c in checks:
        sev = str(c.get("severity", "")).lower()
        blocking = c.get("blocking") in (True, "true") or sev in ("error", "warning")
        code = str(c.get("code") or c.get("id") or c.get("checkId") or c.get("check") or "")
        message = str(c.get("message") or c.get("title") or "")
        severity = "blocker" if blocking else "info"
        if code == ASC_EDITABLE and submitted_state:
            # asc's "Use an editable version state before submission" is advice
            # for a submit; a version Apple already has is no blocker. Run
            # 45615832158 read 1.0.0 WAITING_FOR_REVIEW as one, so readiness
            # stayed red for the whole review.
            severity = "info"
        elif blocking and code in ASC_ADVISORY:
            # Not an App Review requirement (ASC_ADVISORY): shown, never blocking.
            severity = "warning"
        elif blocking and submitted_state and code.startswith(ASC_LOCKED_LISTING):
            # The listing text of a submitted version cannot be edited until it
            # leaves review, so no edit clears this today; the repository's
            # listing test (asc's rules, ported in #58083) guards the next push.
            severity = "warning"
            message = f"{message} (listing locked while the version is {submitted_state}; fix it in the repository's listing for the next editable version)"
        where = str(c.get("resource") or c.get("resourceId") or "")
        if where in RETIRED_SUBSCRIPTIONS and code.startswith("subscriptions."):
            # A retired subscription App Store Connect cannot delete is never
            # sold, so nothing on it blocks a review (RETIRED_SUBSCRIPTIONS).
            severity = "info"
        finding = {
            "rule": f"asc.{code or 'check'}",
            "guideline": guideline_for_asc(code),
            "severity": severity,
            "source": f"asc ({path.stem})",
            "message": message or json.dumps(c)[:200],
            "where": c.get("resource") or c.get("resourceId") or "",
        }
        # asc prints each check under both remediation.steps and checks.
        key = (finding["rule"], str(finding["where"]), str(finding["message"]))
        if key in seen:
            continue
        seen.add(key)
        out.append(finding)
    return out


ASC_EDITABLE = "version.state.editable"
# asc checks that are advice, not App Review requirements, so they show as
# warnings and never block. A subscription promotional image is needed only to
# promote it on the App Store, for offer-code pages or win-back offers (asc's
# own remediation says so; the App Review screenshot is the review one). A
# keyword that repeats a subtitle term wastes keyword space; no guideline
# rejects it. Readiness run 45874464871 counted 10 such blockers on 1.0.0.
ASC_ADVISORY = frozenset({
    "subscriptions.images.recommended",
    "metadata.keywords.overlap_subtitle",
})
# asc check prefixes on a version's listing text (description, keywords,
# subtitle, URLs): App Store Connect locks it while the version is submitted.
ASC_LOCKED_LISTING = ("legal.", "metadata.")
# Subscriptions on the App Store record that are retired: App Store Connect
# cannot delete a subscription, these are never sold (no paywall offers them),
# so asc's findings on them (no promotional image, READY_TO_SUBMIT) are notes,
# never blockers. Run 45748224089 counted two such blockers on the trial.
# cmux-next-ios/AppStoreReview/subscriptions/records.json lists the same ids
# under "retired", and asc_subscription_records.py never writes them.
RETIRED_SUBSCRIPTIONS = {
    "6822947304": "com.cmux.app.pro.trial.monthly",
}
# A version in one of these states is submitted: Apple has it, nothing on it
# can be edited, and asc's editable-state check only says so.
SUBMITTED_STATES = frozenset({
    "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE",
    "PROCESSING_FOR_APP_STORE", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION",
})


# An App Store version in one of these states has been on sale: after it,
# App Store Connect asks every new version for What's New.
ON_SALE_STATES = frozenset({
    "READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "REPLACED_WITH_NEW_VERSION",
    "REMOVED_FROM_SALE", "DEVELOPER_REMOVED_FROM_SALE",
})
ASC_WHATS_NEW = "asc.metadata.required.whats_new"


def is_first_app_store_version(path: Path | None, version: str) -> bool:
    """Whether `version` is the app's first App Store version, from `asc
    versions list --paginate --output json`: the list names it and no other
    version has ever been on sale. Unknown (no list, unreadable, an error
    body) is False, so the gate fails closed."""
    if path is None or not version:
        return False
    try:
        body = json.loads(path.read_text())
    except (OSError, ValueError):
        return False
    data = body.get("data") if isinstance(body, dict) else body
    if not isinstance(data, list) or not data:
        return False
    listed = False
    for item in data:
        if not isinstance(item, dict):
            return False
        attrs = item.get("attributes", item)
        if not isinstance(attrs, dict):
            return False
        if (attrs.get("versionString") or attrs.get("version")) == version:
            listed = True
            continue
        states = {attrs.get("appStoreState"), attrs.get("appVersionState"), attrs.get("state")}
        if states & ON_SALE_STATES:
            return False
    return listed


def asc_validated_version(path: Path) -> str:
    try:
        body = json.loads(path.read_text())
    except (OSError, ValueError):
        return ""
    return str(body.get("versionString") or "") if isinstance(body, dict) else ""


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
        # A skipped test judged nothing: only executed ones count.
        if node.get("nodeType") == "Test Case" and node.get("result") != "Skipped":
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
            "message": f"the {device} suite ran no tests (or skipped every one), so the reviewer path is unjudged there",
            "where": device,
        })
    return out


def blocker_key(f: dict) -> str:
    """A blocker's identity across runs: what failed and where, never the
    on-screen dump or a line number that moves with every edit."""
    where = re.sub(r":\d+$", "", str(f.get("where", "")))
    if f.get("rule") == "uitest.failed":
        # "AppReviewGateUITests/testX(): detail" -> the test, per device.
        return f"uitest.failed|{where}|{str(f.get('message', '')).split(': ', 1)[0]}"
    return f"{f.get('rule', '')}|{where}"


def read_known_blockers(path: Path) -> tuple[set[str], list[dict]]:
    body, unreadable = read_input(path, "known blockers")
    if body is None:
        return set(), unreadable
    try:
        return {str(entry["key"]) for entry in body["blockers"]}, []
    except (KeyError, TypeError) as error:
        return set(), [{"rule": "input.unreadable", "guideline": "2.1", "severity": "blocker", "source": "known blockers",
                        "message": f"{path.name} has no blockers[].key list ({error})", "where": str(path)}]


def ratchet(findings: list[dict], known: set[str]) -> tuple[list[dict], list[str]]:
    """New blockers (fail this change) and known ones no longer seen (fixed:
    remove them from known-blockers.json)."""
    pinned = [f for f in findings if f["severity"] == "blocker"]
    seen = {blocker_key(f) for f in pinned}
    return [f for f in pinned if blocker_key(f) not in known], sorted(known - seen)


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
    lints: list[dict] = []
    for item in args.lint or []:
        body, unreadable = read_input(Path(item), "guideline lint")
        findings += unreadable
        if body is None:
            continue
        lints.append(body)
        lint = lint or body
        findings += [dict(f, source=f"guideline lint ({body.get('lane')})") for f in body["findings"]]
    # A submission lane's build is never judged without Apple's own check:
    # --asc-skipped (a pull request has no release secrets) does not excuse it.
    submission = any(body.get("lane") == "internal-submission" for body in lints)
    asc = None
    validated_version = ""
    for item in args.asc_validate or []:
        if Path(item).is_file():
            asc = (asc or []) + asc_findings(Path(item))
            validated_version = validated_version or asc_validated_version(Path(item))
    versions = Path(args.asc_versions) if args.asc_versions else None
    if asc and any(f["rule"] == ASC_WHATS_NEW for f in asc) and is_first_app_store_version(versions, validated_version):
        # App Store Connect refuses What's New on an app's first App Store
        # version: run 45102744374 failed "STATE_ERROR: Attribute 'whatsNew'
        # cannot be edited at this time" on cmux INTERNAL 1.2.0.
        asc = [f for f in asc if f["rule"] != ASC_WHATS_NEW]
        asc.append({"rule": "asc.whats_new.first-version", "guideline": "2.3", "severity": "info",
                    "source": "asc versions",
                    "message": f"{validated_version} is the app's first App Store version, which takes no What's New "
                               "(App Store Connect refuses it: run 45102744374), so asc's empty What's New is not a blocker",
                    "where": validated_version})
    if asc:
        findings += asc
    if asc is None and (not args.asc_skipped or submission):
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
    # A family the image has no simulator for leaves {family, skipped: true}
    # instead of a result; it counts only for an --expect-device-or-skipped
    # family, never for one that must be walked.
    skipped: set[str] = set()
    for item in args.skipped:
        body, unreadable = read_input(Path(item), "reviewer-path suite")
        findings += unreadable
        if isinstance(body, dict) and body.get("skipped") is True:
            skipped.add(str(body.get("family", "")))
    for family in args.expect_device + [f for f in args.expect_device_or_skipped if f not in skipped]:
        if family not in tests:
            findings.append({"rule": "uitest.missing", "guideline": "2.1(a)", "severity": "blocker",
                             "source": "reviewer-path suite",
                             "message": f"no {family} suite result reached the report: the reviewer path is unjudged there",
                             "where": family})
    known: set[str] | None = None
    if args.known_blockers:
        known, unreadable = read_known_blockers(Path(args.known_blockers))
        findings += unreadable
        if args.proposed_known_blockers:
            # A pull request is judged on its base's list, and a key it adds
            # to the list is itself a blocker: pinning the regression it brings
            # would otherwise pass it.
            proposed, unreadable = read_known_blockers(Path(args.proposed_known_blockers))
            findings += unreadable
            findings += [{"rule": "known-blockers.added", "guideline": "2.1", "severity": "blocker",
                          "source": "known blockers", "where": key,
                          "message": f"this change adds {key} to {KNOWN_BLOCKERS_FILE}; fix the blocker instead"}
                         for key in sorted(proposed - known)]
    md = render(findings, lint, asc, tests)
    new: list[dict] | None = None
    if known is not None:
        new, fixed = ratchet(findings, known)
        lines = ["", "### New in this change", ""]
        if new:
            lines.append(f"**{len(new)} new blocking** (not in `{KNOWN_BLOCKERS_FILE}`): this change makes the app "
                         "fail App Review where it passed. Fix it; never add it to that file to get past this.")
            lines += [f"- `{blocker_key(f)}`: {str(f['message'])[:300]}" for f in new]
        else:
            lines.append("No new blocker: every blocker above was already known.")
        if fixed:
            lines += ["", f"Fixed here or not seen this run (remove from `{KNOWN_BLOCKERS_FILE}` once fixed):"]
            lines += [f"- `{key}`" for key in fixed]
        md += "\n".join(lines)
    if args.out:
        Path(args.out).write_text(md + "\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            fh.write(md + "\n")
    print(md)
    if new is not None:
        return 1 if new else 0
    return 1 if any(f["severity"] == "blocker" for f in findings) else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    lint = sub.add_parser("lint")
    lint.add_argument("--source-root", default=".")
    lint.add_argument("--lane", choices=LANES, default="appstore")
    lint.add_argument("--app")
    lint.add_argument("--ipa")
    lint.add_argument("--check-urls", action="store_true")
    lint.add_argument("--json")
    lint.add_argument("--expect-commit", default="",
                      help="the full SHA the binary's CmuxMobileSourceCommit must name")
    report = sub.add_parser("report")
    report.add_argument("--lint", action="append")
    report.add_argument("--asc-validate", action="append")
    report.add_argument("--asc-versions",
                        help="`asc versions list --paginate --output json`: an app's first App Store version takes no What's New")
    report.add_argument("--asc-skipped", action="store_true",
                        help="asc validate cannot run for this event (a PR has no release secrets)")
    report.add_argument("--xcresult-json", action="append")
    report.add_argument("--suite-log", action="append", default=[],
                        help="a suite's xcodebuild log; its GATE-NOTE lines become warnings")
    report.add_argument("--suite-status", action="append", default=[],
                        help="{family, exit} from the suite step: a nonzero exit with no failed test blocks")
    report.add_argument("--expect-lint", action="store_true",
                        help="a missing --lint result is a blocker: the gate fails closed")
    report.add_argument("--expect-device", action="append", default=[],
                        help="a device family (iphone, ipad) whose suite result must be present")
    report.add_argument("--expect-device-or-skipped", action="append", default=[],
                        help="a device family (duo) whose suite result or --skipped marker must be present")
    report.add_argument("--skipped", action="append", default=[],
                        help="{family, skipped: true}: the image had no simulator for that family")
    report.add_argument("--known-blockers",
                        help="known-blockers.json: fail only on a blocker not listed there (a push or pull request)")
    report.add_argument("--proposed-known-blockers",
                        help="the change's own known-blockers.json: every key it adds over --known-blockers blocks")
    report.add_argument("--out")
    version = sub.add_parser("version")
    version.add_argument("--source-root", default=".")
    version.add_argument("--lane", choices=LANES, default="appstore")
    families = sub.add_parser("families", help="the app's shipped device families (1 iPhone, 2 iPad), comma-separated")
    families.add_argument("--source-root", default=".")
    args = parser.parse_args(argv)
    if args.cmd == "families":
        print(",".join(sorted(app_device_families(Path(args.source_root)))))
        return 0
    if args.cmd == "version":
        found = marketing_version(Path(args.source_root), args.lane)
        print(found)
        return 0 if found else 1
    return cmd_lint(args) if args.cmd == "lint" else cmd_report(args)


if __name__ == "__main__":
    sys.exit(main())
