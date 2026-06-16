#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import argparse
import hmac
import json
import os
import plistlib
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


MESSAGES = {
    "en": {
        "title": "cmux iOS Simulator",
        "statusBooting": "Preparing simulator...",
        "statusReady": "Simulator stream ready",
        "statusInputReady": "Input bridge ready",
        "statusInputUnavailable": "Input bridge unavailable",
        "statusInputFailed": "Input event failed",
        "emptyFrame": "Waiting for the first simulator frame",
    },
    "ja": {
        "title": "cmux iOS シミュレータ",
        "statusBooting": "シミュレータを準備しています...",
        "statusReady": "シミュレータストリームの準備ができました",
        "statusInputReady": "入力ブリッジの準備ができました",
        "statusInputUnavailable": "入力ブリッジを利用できません",
        "statusInputFailed": "入力イベントに失敗しました",
        "emptyFrame": "最初のシミュレータフレームを待っています",
    },
}

SIMCTL_TIMEOUT_SECONDS = 60
SIMCTL_BOOT_TIMEOUT_SECONDS = 300
XCODEBUILD_DISCOVERY_TIMEOUT_SECONDS = 300
XCODEBUILD_BUILD_TIMEOUT_SECONDS = 1800
SCREENSHOT_TIMEOUT_SECONDS = 10
INPUT_TIMEOUT_SECONDS = 30
MAX_INPUT_BYTES = 65536

INDEX_HTML = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title></title>
<style>
  :root {
    color-scheme: dark;
    --bg: #0b0d10;
    --panel: rgba(17, 24, 31, 0.88);
    --text: #f4f7fb;
    --muted: #a7b0bd;
    --accent: #49c28f;
    --warn: #f0b35b;
    --error: #ef6f6c;
  }
  html, body {
    width: 100%;
    height: 100%;
    margin: 0;
    overflow: hidden;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
  }
  body {
    display: grid;
    place-items: center;
  }
  #stage {
    width: 100vw;
    height: 100vh;
    display: grid;
    place-items: center;
    outline: none;
  }
  #screen {
    max-width: 100vw;
    max-height: 100vh;
    width: auto;
    height: auto;
    display: block;
    user-select: none;
    -webkit-user-drag: none;
    touch-action: none;
    cursor: crosshair;
  }
  #empty {
    color: var(--muted);
    font-size: 13px;
  }
  #status {
    position: fixed;
    left: 12px;
    bottom: 12px;
    max-width: min(520px, calc(100vw - 24px));
    padding: 8px 10px;
    border-radius: 8px;
    background: var(--panel);
    color: var(--text);
    font-size: 12px;
    line-height: 1.35;
    box-shadow: 0 8px 30px rgba(0, 0, 0, 0.28);
  }
  #status[data-state="ready"] { border-left: 3px solid var(--accent); }
  #status[data-state="warn"] { border-left: 3px solid var(--warn); }
  #status[data-state="error"] { border-left: 3px solid var(--error); }
</style>
</head>
<body>
<main id="stage" tabindex="0" aria-label="">
  <img id="screen" alt="">
  <div id="empty"></div>
</main>
<section id="status" data-state="warn">
  <div id="statusText"></div>
</section>
<script>
const MESSAGES = __MESSAGES_JSON__;
const lang = (navigator.language || "en").toLowerCase().startsWith("ja") ? "ja" : "en";
const t = MESSAGES[lang] || MESSAGES.en;
document.documentElement.lang = lang;
document.title = t.title;

const screen = document.getElementById("screen");
const empty = document.getElementById("empty");
const stage = document.getElementById("stage");
const statusBox = document.getElementById("status");
const statusText = document.getElementById("statusText");
let seq = 0;
let metadata = {};

function withAuth(path) {
  const auth = window.location.search || "";
  if (!auth) {
    return path;
  }
  return path + (path.includes("?") ? "&" + auth.slice(1) : auth);
}

screen.alt = t.title;
stage.setAttribute("aria-label", t.title);
empty.textContent = t.emptyFrame;
statusText.textContent = t.statusBooting;

function setStatus(text, state) {
  statusText.textContent = text;
  statusBox.dataset.state = state;
}

async function refreshMetadata() {
  try {
    const response = await fetch(withAuth("/metadata"), { cache: "no-store" });
    metadata = await response.json();
    setStatus(metadata.input_available ? t.statusInputReady : t.statusInputUnavailable, metadata.input_available ? "ready" : "warn");
  } catch (_) {
    setStatus(t.statusBooting, "warn");
  }
}

function loadFrame() {
  const image = new Image();
  image.onload = () => {
    screen.src = image.src;
    screen.hidden = false;
    empty.hidden = true;
    window.setTimeout(loadFrame, 250);
  };
  image.onerror = () => {
    window.setTimeout(loadFrame, 750);
  };
  image.src = withAuth(`/frame?seq=${seq++}`);
}

function pointForEvent(event) {
  const rect = screen.getBoundingClientRect();
  if (!rect.width || !rect.height || !screen.naturalWidth || !screen.naturalHeight) {
    return null;
  }
  const x = Math.max(0, Math.min(screen.naturalWidth, (event.clientX - rect.left) * screen.naturalWidth / rect.width));
  const y = Math.max(0, Math.min(screen.naturalHeight, (event.clientY - rect.top) * screen.naturalHeight / rect.height));
  return { x, y, width: screen.naturalWidth, height: screen.naturalHeight };
}

async function sendInput(event) {
  try {
    const response = await fetch(withAuth("/input"), {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(event),
    });
    const payload = await response.json();
    if (!payload.ok) {
      setStatus(payload.unsupported ? t.statusInputUnavailable : t.statusInputFailed, payload.unsupported ? "warn" : "error");
    } else if (metadata.input_available) {
      setStatus(t.statusInputReady, "ready");
    }
  } catch (_) {
    setStatus(t.statusInputFailed, "error");
  }
}

let pointerDown = null;
screen.addEventListener("pointerdown", event => {
  stage.focus();
  pointerDown = pointForEvent(event);
});
screen.addEventListener("pointerup", event => {
  const point = pointForEvent(event);
  if (!point || !pointerDown) {
    return;
  }
  const moved = Math.hypot(point.x - pointerDown.x, point.y - pointerDown.y);
  if (moved < 12) {
    sendInput({ type: "tap", ...point });
  }
  pointerDown = null;
});
screen.addEventListener("wheel", event => {
  const point = pointForEvent(event);
  if (!point) {
    return;
  }
  event.preventDefault();
  sendInput({ type: "scroll", deltaX: event.deltaX, deltaY: event.deltaY, ...point });
}, { passive: false });

stage.addEventListener("keydown", event => {
  if (event.metaKey || event.ctrlKey || event.altKey) {
    return;
  }
  if (event.key.length === 1) {
    sendInput({ type: "text", text: event.key });
  } else {
    sendInput({ type: "key", key: event.key });
  }
});

stage.focus();
refreshMetadata();
window.setInterval(refreshMetadata, 5000);
loadFrame();
</script>
</body>
</html>
"""


class CommandError(RuntimeError):
    def __init__(self, message, args=None, returncode=None, stdout="", stderr=""):
        super().__init__(message)
        self.args_list = args or []
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def timeout_output(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return str(value)


def log(message):
    print(message, file=sys.stderr, flush=True)


def run(args, cwd=None, check=True, input_text=None, timeout=None):
    log("$ " + " ".join(shlex.quote(str(part)) for part in args))
    try:
        completed = subprocess.run(
            [str(part) for part in args],
            cwd=str(cwd) if cwd else None,
            input=input_text,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise CommandError(
            f"command timed out after {timeout} seconds",
            args=args,
            stdout=timeout_output(error.stdout),
            stderr=timeout_output(error.stderr),
        ) from error
    if completed.stdout.strip():
        log(completed.stdout.rstrip())
    if completed.stderr.strip():
        log(completed.stderr.rstrip())
    if check and completed.returncode != 0:
        raise CommandError(
            f"command failed with status {completed.returncode}",
            args=args,
            returncode=completed.returncode,
            stdout=completed.stdout,
            stderr=completed.stderr,
        )
    return completed


def run_streaming(args, cwd=None, check=True, timeout=None):
    log("$ " + " ".join(shlex.quote(str(part)) for part in args))
    try:
        completed = subprocess.run(
            [str(part) for part in args],
            cwd=str(cwd) if cwd else None,
            stdout=sys.stderr,
            stderr=sys.stderr,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise CommandError(
            f"command timed out after {timeout} seconds",
            args=args,
            returncode=None,
            stdout=timeout_output(error.stdout),
            stderr=timeout_output(error.stderr),
        ) from error
    if check and completed.returncode != 0:
        raise CommandError(
            f"command failed with status {completed.returncode}",
            args=args,
            returncode=completed.returncode,
        )
    return completed


def resolve_path(raw, cwd):
    path = Path(raw).expanduser()
    if not path.is_absolute():
        path = cwd / path
    return path.resolve()


def simctl_json(*args):
    completed = run(["/usr/bin/xcrun", "simctl", *args], check=True, timeout=SIMCTL_TIMEOUT_SECONDS)
    return json.loads(completed.stdout)


def available_devices():
    payload = simctl_json("list", "devices", "available", "-j")
    devices = []
    for runtime, items in payload.get("devices", {}).items():
        if "iOS" not in runtime:
            continue
        for item in items:
            if item.get("isAvailable", True):
                item = dict(item)
                item["runtime"] = runtime
                devices.append(item)
    return devices


def select_device(requested):
    devices = available_devices()
    if not devices:
        raise CommandError("no available iOS simulator devices found")

    if requested:
        needle = requested.strip().lower()
        for device in devices:
            if device.get("udid", "").lower() == needle:
                return device
        for device in devices:
            if device.get("name", "").lower() == needle:
                return device
        for device in devices:
            if needle in device.get("name", "").lower():
                return device
        raise CommandError(f"simulator device not found: {requested}")

    for device in devices:
        if device.get("state") == "Booted" and "iphone" in device.get("name", "").lower():
            return device
    for device in devices:
        if device.get("state") == "Booted":
            return device
    for device in devices:
        if "iphone" in device.get("name", "").lower():
            return device
    return devices[0]


def boot_device(udid):
    completed = run(["/usr/bin/xcrun", "simctl", "boot", udid], check=False, timeout=SIMCTL_BOOT_TIMEOUT_SECONDS)
    if completed.returncode != 0:
        combined = f"{completed.stdout}\n{completed.stderr}".lower()
        if "booted" not in combined and "current state" not in combined:
            raise CommandError(
                "failed to boot simulator",
                args=["/usr/bin/xcrun", "simctl", "boot", udid],
                returncode=completed.returncode,
                stdout=completed.stdout,
                stderr=completed.stderr,
            )
    run(["/usr/bin/xcrun", "simctl", "bootstatus", udid, "-b"], check=True, timeout=SIMCTL_BOOT_TIMEOUT_SECONDS)


def discover_xcode_container(cwd, workspace, project):
    if workspace and project:
        raise CommandError("pass only one of --xcode-workspace or --xcode-project")
    if workspace:
        path = resolve_path(workspace, cwd)
        if not path.exists():
            raise CommandError(f"workspace not found: {path}")
        return ("workspace", path)
    if project:
        path = resolve_path(project, cwd)
        if not path.exists():
            raise CommandError(f"project not found: {path}")
        return ("project", path)

    workspaces = sorted(cwd.glob("*.xcworkspace"))
    projects = sorted(cwd.glob("*.xcodeproj"))
    if len(workspaces) == 1:
        return ("workspace", workspaces[0].resolve())
    if not workspaces and len(projects) == 1:
        return ("project", projects[0].resolve())
    if workspaces or projects:
        raise CommandError("multiple Xcode containers found; pass --xcode-workspace or --xcode-project")
    raise CommandError("no .xcworkspace or .xcodeproj found; pass --app or an Xcode container")


def xcode_container_args(kind, path):
    if kind == "workspace":
        return ["-workspace", str(path)]
    return ["-project", str(path)]


def discover_scheme(kind, path, cwd):
    completed = run(
        ["/usr/bin/xcrun", "xcodebuild", "-list", "-json", *xcode_container_args(kind, path)],
        cwd=cwd,
        check=True,
        timeout=XCODEBUILD_DISCOVERY_TIMEOUT_SECONDS,
    )
    payload = json.loads(completed.stdout)
    container = payload.get(kind, {}) if kind in payload else payload.get("project", {})
    schemes = container.get("schemes", [])
    if len(schemes) == 1:
        return schemes[0]
    candidates = [scheme for scheme in schemes if not scheme.lower().endswith("tests")]
    if len(candidates) == 1:
        return candidates[0]
    if not schemes:
        raise CommandError("no shared Xcode schemes found")
    raise CommandError("multiple Xcode schemes found; pass --scheme")


def default_derived_data(cwd, scheme):
    safe = "".join(ch if ch.isalnum() or ch in "._-" else "-" for ch in f"{cwd.name}-{scheme}")
    return Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData" / "cmux-ios-loop" / safe


def build_app(args, cwd, udid):
    kind, container = discover_xcode_container(cwd, args.xcode_workspace, args.xcode_project)
    scheme = args.scheme or discover_scheme(kind, container, cwd)
    configuration = args.configuration or "Debug"
    derived_data = resolve_path(args.derived_data, cwd) if args.derived_data else default_derived_data(cwd, scheme)
    destination = f"platform=iOS Simulator,id={udid}"
    base = [
        "/usr/bin/xcrun",
        "xcodebuild",
        *xcode_container_args(kind, container),
        "-scheme",
        scheme,
        "-configuration",
        configuration,
        "-sdk",
        "iphonesimulator",
        "-destination",
        destination,
        "-derivedDataPath",
        str(derived_data),
    ]
    run_streaming([*base, "build"], cwd=cwd, check=True, timeout=XCODEBUILD_BUILD_TIMEOUT_SECONDS)
    settings = run(
        [*base, "-showBuildSettings", "-json"],
        cwd=cwd,
        check=True,
        timeout=XCODEBUILD_DISCOVERY_TIMEOUT_SECONDS,
    )
    app_path = app_path_from_build_settings(settings.stdout)
    if app_path is None:
        app_path = newest_built_app(derived_data)
    if app_path is None or not app_path.exists():
        raise CommandError("xcodebuild completed but no built .app was found")
    return app_path.resolve(), scheme, str(derived_data)


def app_path_from_build_settings(raw):
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return None
    candidates = []
    for item in payload if isinstance(payload, list) else []:
        settings = item.get("buildSettings", {})
        wrapper = settings.get("WRAPPER_NAME")
        target_dir = settings.get("TARGET_BUILD_DIR")
        product_type = settings.get("PRODUCT_TYPE", "")
        wrapper_ext = settings.get("WRAPPER_EXTENSION", "")
        if not wrapper or not target_dir:
            continue
        if wrapper_ext == "app" or wrapper.endswith(".app") or product_type == "com.apple.product-type.application":
            candidates.append(Path(target_dir) / wrapper)
    return candidates[0] if candidates else None


def newest_built_app(derived_data):
    products = derived_data / "Build" / "Products"
    if not products.exists():
        return None
    apps = [path for path in products.rglob("*.app") if path.is_dir() and not path.name.endswith(".appex")]
    if not apps:
        return None
    return max(apps, key=lambda path: path.stat().st_mtime)


def bundle_id_for_app(app_path):
    info_plist = app_path / "Info.plist"
    if not info_plist.exists():
        raise CommandError(f"Info.plist not found in app bundle: {app_path}")
    with info_plist.open("rb") as handle:
        payload = plistlib.load(handle)
    bundle_id = payload.get("CFBundleIdentifier")
    if not bundle_id:
        raise CommandError(f"CFBundleIdentifier not found in app bundle: {app_path}")
    return bundle_id


def install_and_launch(udid, app_path, bundle_id):
    run(["/usr/bin/xcrun", "simctl", "install", udid, str(app_path)], check=True, timeout=SIMCTL_BOOT_TIMEOUT_SECONDS)
    run(["/usr/bin/xcrun", "simctl", "launch", udid, bundle_id], check=True, timeout=SIMCTL_TIMEOUT_SECONDS)


class SimulatorState:
    def __init__(self, device, app_path, bundle_id, input_command, auth_token):
        self.device = device
        self.app_path = str(app_path) if app_path else None
        self.bundle_id = bundle_id
        self.input_command = input_command
        self.auth_token = auth_token
        self.idb_path = shutil.which("idb")
        self.frame_lock = threading.Lock()
        self.last_frame = None
        self.last_frame_error = None

    @property
    def input_available(self):
        return bool(self.input_command or self.idb_path)

    def metadata(self):
        return {
            "device": self.device,
            "app_path": self.app_path,
            "bundle_id": self.bundle_id,
            "input_available": self.input_available,
        }

    def capture_frame(self):
        if not self.frame_lock.acquire(blocking=False):
            if self.last_frame:
                return self.last_frame, True
            return None, False
        try:
            try:
                raw = subprocess.run(
                    ["/usr/bin/xcrun", "simctl", "io", self.device["udid"], "screenshot", "--type=png", "-"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=SCREENSHOT_TIMEOUT_SECONDS,
                )
            except subprocess.TimeoutExpired as error:
                self.last_frame_error = f"screenshot timed out after {SCREENSHOT_TIMEOUT_SECONDS} seconds"
                if error.stderr:
                    self.last_frame_error += ": " + timeout_output(error.stderr)
                return self.last_frame, True
            if raw.returncode == 0 and raw.stdout:
                self.last_frame = raw.stdout
                self.last_frame_error = None
                return raw.stdout, False
            self.last_frame_error = raw.stderr.decode("utf-8", errors="replace")
            return self.last_frame, True
        finally:
            self.frame_lock.release()

    def handle_input(self, event):
        if self.input_command:
            return self.run_input_command(event)
        if self.idb_path:
            return self.run_idb(event)
        return {
            "ok": False,
            "unsupported": True,
            "code": "input_bridge_unavailable",
        }

    def run_input_command(self, event):
        command = shlex.split(self.input_command)
        if not command:
            return {"ok": False, "code": "input_command_empty"}
        env = os.environ.copy()
        env["CMUX_IOS_DEVICE_UDID"] = self.device["udid"]
        env["CMUX_IOS_BUNDLE_ID"] = self.bundle_id or ""
        env["CMUX_IOS_INPUT_TYPE"] = str(event.get("type", ""))
        for key in ("x", "y", "width", "height", "deltaX", "deltaY", "text", "key"):
            if key in event:
                env[f"CMUX_IOS_{key.upper()}"] = str(event[key])
        try:
            completed = subprocess.run(
                command,
                input=json.dumps(event),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                timeout=INPUT_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            log(f"input command timed out after {INPUT_TIMEOUT_SECONDS} seconds")
            if error.stdout:
                log("input command stdout:\n" + timeout_output(error.stdout).rstrip())
            if error.stderr:
                log("input command stderr:\n" + timeout_output(error.stderr).rstrip())
            return {"ok": False, "code": "input_command_timeout"}
        if completed.returncode == 0:
            return {"ok": True}
        log(f"input command failed with status {completed.returncode}")
        if completed.stdout.strip():
            log("input command stdout:\n" + completed.stdout.rstrip())
        if completed.stderr.strip():
            log("input command stderr:\n" + completed.stderr.rstrip())
        return {
            "ok": False,
            "code": "input_command_failed",
        }

    def run_idb(self, event):
        event_type = event.get("type")
        udid = self.device["udid"]
        if event_type == "tap":
            args = ["ui", "tap", str(round(float(event.get("x", 0)))), str(round(float(event.get("y", 0))))]
        elif event_type == "scroll":
            x = float(event.get("x", 0))
            y = float(event.get("y", 0))
            dx = float(event.get("deltaX", 0))
            dy = float(event.get("deltaY", 0))
            args = ["ui", "swipe", str(round(x)), str(round(y)), str(round(x - dx)), str(round(y - dy))]
        elif event_type == "text":
            args = ["ui", "input", str(event.get("text", ""))]
        elif event_type == "key":
            args = ["ui", "key", str(event.get("key", ""))]
        else:
            return {"ok": False, "code": "unsupported_input_type", "input_type": event_type}

        try:
            completed = subprocess.run(
                [self.idb_path, "--udid", udid, *args],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=INPUT_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            log(f"idb input timed out after {INPUT_TIMEOUT_SECONDS} seconds")
            if error.stdout:
                log("idb stdout:\n" + timeout_output(error.stdout).rstrip())
            if error.stderr:
                log("idb stderr:\n" + timeout_output(error.stderr).rstrip())
            return {"ok": False, "code": "input_bridge_timeout"}
        if completed.returncode == 0:
            return {"ok": True}
        log(f"idb input failed with status {completed.returncode}")
        if completed.stdout.strip():
            log("idb stdout:\n" + completed.stdout.rstrip())
        if completed.stderr.strip():
            log("idb stderr:\n" + completed.stderr.rstrip())
        return {
            "ok": False,
            "code": "input_bridge_failed",
        }


class SimulatorRequestHandler(BaseHTTPRequestHandler):
    server_version = "cmux-ios-sim-server/1.0"

    @property
    def state(self):
        return self.server.simulator_state

    def has_valid_token(self, parsed):
        tokens = urllib.parse.parse_qs(parsed.query).get("token", [])
        return any(hmac.compare_digest(token, self.state.auth_token) for token in tokens)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/health" and not self.has_valid_token(parsed):
            self.write_json({"ok": False, "code": "unauthorized"}, status=403)
            return
        if parsed.path == "/":
            self.write_html()
        elif parsed.path == "/frame":
            self.write_frame()
        elif parsed.path == "/metadata":
            self.write_json(self.state.metadata())
        elif parsed.path == "/health":
            self.write_json({"ok": True})
        else:
            self.send_error(404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/input":
            self.send_error(404)
            return
        if not self.has_valid_token(parsed):
            self.write_json({"ok": False, "code": "unauthorized"}, status=403)
            return
        try:
            length = int(self.headers.get("content-length") or "0")
        except ValueError:
            self.write_json({"ok": False, "code": "invalid_content_length"}, status=400)
            return
        if length < 0 or length > MAX_INPUT_BYTES:
            self.write_json({"ok": False, "code": "input_too_large"}, status=413)
            return
        raw = self.rfile.read(length)
        try:
            event = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self.write_json({"ok": False, "code": "invalid_json"}, status=400)
            return
        result = self.state.handle_input(event)
        self.write_json(result, status=200 if result.get("ok") else 501 if result.get("unsupported") else 500)

    def write_html(self):
        body = INDEX_HTML.replace("__MESSAGES_JSON__", json.dumps(MESSAGES, ensure_ascii=False))
        data = body.encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def write_frame(self):
        frame, stale = self.state.capture_frame()
        if not frame:
            self.write_json({"ok": False, "code": "frame_unavailable", "detail": self.state.last_frame_error}, status=503)
            return
        self.send_response(200)
        self.send_header("content-type", "image/png")
        self.send_header("content-length", str(len(frame)))
        self.send_header("cache-control", "no-store")
        if stale:
            self.send_header("x-cmux-frame-stale", "true")
        self.end_headers()
        self.wfile.write(frame)

    def write_json(self, payload, status=200):
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        log("%s - %s" % (self.address_string(), fmt % args))


def parse_args(argv):
    parser = argparse.ArgumentParser(prog="cmux-ios-sim-server")
    subparsers = parser.add_subparsers(dest="command", required=True)
    serve = subparsers.add_parser("serve")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=0)
    serve.add_argument("--cwd", default=os.getcwd())
    serve.add_argument("--app")
    serve.add_argument("--bundle-id")
    serve.add_argument("--xcode-workspace")
    serve.add_argument("--xcode-project")
    serve.add_argument("--scheme")
    serve.add_argument("--configuration", default="Debug")
    serve.add_argument("--derived-data")
    serve.add_argument("--device")
    serve.add_argument("--input-command")
    serve.add_argument("--no-build", action="store_true")
    return parser.parse_args(argv)


def serve(args):
    cwd = resolve_path(args.cwd, Path.cwd())
    device = select_device(args.device)
    log(f"selected simulator: {device.get('name')} ({device.get('udid')})")
    boot_device(device["udid"])

    app_path = resolve_path(args.app, cwd) if args.app else None
    scheme = args.scheme
    derived_data = None
    if not args.no_build and app_path is None:
        app_path, scheme, derived_data = build_app(args, cwd, device["udid"])
    if app_path is None:
        raise CommandError("--app is required when --no-build is used")
    if not app_path.exists():
        raise CommandError(f"app bundle not found: {app_path}")

    bundle_id = args.bundle_id or bundle_id_for_app(app_path)
    install_and_launch(device["udid"], app_path, bundle_id)

    input_command = args.input_command or os.environ.get("CMUX_IOS_INPUT_COMMAND")
    auth_token = secrets.token_urlsafe(32)
    state = SimulatorState(
        device=device,
        app_path=app_path,
        bundle_id=bundle_id,
        input_command=input_command,
        auth_token=auth_token,
    )
    server = ThreadingHTTPServer((args.host, args.port), SimulatorRequestHandler)
    server.simulator_state = state
    host, port = server.server_address
    url = f"http://{host}:{port}/?token={urllib.parse.quote(auth_token)}"

    def shutdown(signum, _frame):
        log(f"received signal {signum}, shutting down")
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    ready = {
        "url": url,
        "device": device,
        "app_path": str(app_path),
        "bundle_id": bundle_id,
        "scheme": scheme,
        "derived_data": derived_data,
        "input_available": state.input_available,
    }
    print(json.dumps(ready, ensure_ascii=False), flush=True)
    log(f"serving simulator stream at {url}")
    server.serve_forever()


def main(argv):
    args = parse_args(argv)
    try:
        if args.command == "serve":
            serve(args)
        else:
            raise CommandError(f"unsupported command: {args.command}")
    except CommandError as error:
        log(f"error: {error}")
        if getattr(error, "stderr", ""):
            log(error.stderr.rstrip())
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
