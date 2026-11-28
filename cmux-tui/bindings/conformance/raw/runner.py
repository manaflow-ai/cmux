#!/usr/bin/env python3
"""Run the explicitly raw protocol-12 SDK conformance suite."""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import selectors
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Mapping, Sequence


HERE = Path(__file__).resolve().parent
BINDINGS = HERE.parent.parent
MUX_DIR = BINDINGS.parent
ROOT = MUX_DIR.parent
FIXTURES = HERE / "fixtures.json"
RAW_CATALOGS = (
    (HERE / "catalog-v10.json", "34741cdc96", 10),
    (HERE / "catalog-v11.json", "236f57ff60", 11),
)
BUILD = HERE.parent / ".build" / "raw"
LANGUAGES = ("python", "typescript", "rust", "go", "java", "cpp", "zig")
UINT64_MAX = 18_446_744_073_709_551_615


class ConformanceFailure(Exception):
    pass


class ToolchainMissing(ConformanceFailure):
    pass


@dataclasses.dataclass(frozen=True)
class AdapterSpec:
    language: str
    tools: tuple[str, ...]
    build: tuple[tuple[str, ...], ...]
    command: tuple[str, ...]
    cwd: Path


@dataclasses.dataclass
class CaseResult:
    language: str
    name: str
    status: str
    detail: str = ""


def adapter_specs() -> dict[str, AdapterSpec]:
    adapters = HERE / "adapters"
    zig = os.environ.get("CMUX_ZIG", "zig")
    return {
        "python": AdapterSpec(
            "python",
            ("python3",),
            (),
            ("python3", str(adapters / "python" / "adapter.py")),
            ROOT,
        ),
        "typescript": AdapterSpec(
            "typescript",
            ("node", "npm"),
            (("npm", "run", "build", "--silent"),),
            ("node", str(adapters / "typescript" / "adapter.mjs")),
            BINDINGS / "typescript",
        ),
        "rust": AdapterSpec(
            "rust",
            ("cargo",),
            (
                (
                    "cargo",
                    "build",
                    "--quiet",
                    "--manifest-path",
                    str(adapters / "rust" / "Cargo.toml"),
                    "--target-dir",
                    str(BUILD / "rust"),
                ),
            ),
            (str(BUILD / "rust" / "debug" / "cmux-conformance-rust"),),
            ROOT,
        ),
        "go": AdapterSpec(
            "go",
            ("go",),
            (
                (
                    "go",
                    "build",
                    "-o",
                    str(BUILD / "go" / "cmux-conformance-go"),
                    str(adapters / "go" / "main.go"),
                ),
            ),
            (str(BUILD / "go" / "cmux-conformance-go"),),
            BINDINGS / "go",
        ),
        "java": AdapterSpec(
            "java",
            ("java", "javac"),
            (("bash", str(adapters / "java" / "build.sh"), str(BUILD / "java")),),
            (
                "java",
                "-cp",
                str(BUILD / "java"),
                "com.cmux.conformance.Adapter",
            ),
            ROOT,
        ),
        "cpp": AdapterSpec(
            "cpp",
            ("cmake",),
            (
                (
                    "cmake",
                    "-S",
                    str(adapters / "cpp"),
                    "-B",
                    str(BUILD / "cpp"),
                ),
                (
                    "cmake",
                    "--build",
                    str(BUILD / "cpp"),
                    "--parallel",
                ),
            ),
            (str(BUILD / "cpp" / "cmux-conformance-cpp"),),
            ROOT,
        ),
        "zig": AdapterSpec(
            "zig",
            (zig,),
            (
                (
                    zig,
                    "build",
                    "--build-file",
                    str(adapters / "zig" / "build.zig"),
                    "--prefix",
                    str(BUILD / "zig"),
                    "--cache-dir",
                    str(BUILD / "zig-cache"),
                ),
            ),
            (str(BUILD / "zig" / "bin" / "cmux-conformance-zig"),),
            ROOT,
        ),
    }


class Adapter:
    def __init__(self, spec: AdapterSpec) -> None:
        self.spec = spec

    def check_tools(self) -> None:
        missing = [tool for tool in self.spec.tools if shutil.which(tool) is None]
        if missing:
            raise ToolchainMissing(f"missing toolchain: {', '.join(missing)}")

    def build(self) -> None:
        self.check_tools()
        (BUILD / self.spec.language).mkdir(parents=True, exist_ok=True)
        for command in self.spec.build:
            result = subprocess.run(
                command,
                cwd=self.spec.cwd,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=300,
                check=False,
            )
            if result.returncode != 0:
                raise ConformanceFailure(
                    f"adapter build failed ({' '.join(command)}):\n{result.stdout}"
                )

    def request(self, payload: Mapping[str, Any], timeout: float = 10.0) -> dict[str, Any]:
        process = subprocess.Popen(
            self.spec.command,
            cwd=self.spec.cwd,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            request_line = json.dumps(payload, separators=(",", ":"), ensure_ascii=False) + "\n"
            stdout, stderr = process.communicate(request_line, timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
            raise ConformanceFailure(
                f"adapter timed out after {timeout:.1f}s; stdout={stdout!r}; stderr={stderr!r}"
            )
        if process.returncode != 0:
            raise ConformanceFailure(
                f"adapter exited {process.returncode}; stdout={stdout!r}; stderr={stderr!r}"
            )
        lines = [line for line in stdout.splitlines() if line.strip()]
        if len(lines) != 1:
            raise ConformanceFailure(
                f"adapter must return exactly one NDJSON object; stdout={stdout!r}; stderr={stderr!r}"
            )
        try:
            value = json.loads(lines[0])
        except json.JSONDecodeError as exc:
            raise ConformanceFailure(
                f"adapter returned invalid JSON: {exc}; stdout={stdout!r}; stderr={stderr!r}"
            ) from exc
        if not isinstance(value, dict):
            raise ConformanceFailure(f"adapter response must be an object, got {type(value).__name__}")
        if value.get("contract_version") != 1:
            raise ConformanceFailure(
                f"adapter contract_version must be 1, got {value.get('contract_version')!r}"
            )
        if value.get("id") != payload.get("id"):
            raise ConformanceFailure(
                f"adapter response id {value.get('id')!r} != request id {payload.get('id')!r}"
            )
        return value


class FakeServer:
    def __init__(self, spec: Mapping[str, Any]) -> None:
        self.spec = dict(spec)
        self.directory = Path(tempfile.mkdtemp(prefix="cmux-sdk-conformance-"))
        self.socket_path = self.directory / "server.sock"
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.socket_path))
        self.listener.listen(4)
        self.listener.settimeout(0.1)
        self.stop_event = threading.Event()
        self.done = threading.Event()
        self.connected = threading.Event()
        self.bytes_received = threading.Event()
        self.error: BaseException | None = None
        self.requests: list[dict[str, Any]] = []
        self.connection_threads: list[threading.Thread] = []
        self.behavior = str(self.spec["behavior"])
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "FakeServer":
        self.thread.start()
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        self.stop_event.set()
        try:
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            probe.connect(str(self.socket_path))
            probe.close()
        except OSError:
            pass
        self.thread.join(timeout=3)
        for thread in self.connection_threads:
            thread.join(timeout=1)
        self.listener.close()
        try:
            self.socket_path.unlink(missing_ok=True)
            self.directory.rmdir()
        except OSError:
            pass
        if exc is None and self.error is not None:
            raise ConformanceFailure(f"fake server failed: {self.error}") from self.error

    def _serve(self) -> None:
        try:
            while not self.stop_event.is_set() and not self.done.is_set():
                try:
                    connection, _ = self.listener.accept()
                except socket.timeout:
                    continue
                self.connected.set()
                thread = threading.Thread(
                    target=self._handle_connection,
                    args=(connection,),
                    daemon=True,
                )
                self.connection_threads.append(thread)
                thread.start()
        except BaseException as exc:
            self.error = exc
            self.done.set()

    def _handle_connection(self, connection: socket.socket) -> None:
        try:
            with connection:
                if self.behavior == "no-write":
                    self._no_write(connection)
                elif self.behavior == "request-shape":
                    self._request_shape(connection)
                elif self.behavior == "authority":
                    self._authority(connection)
                else:
                    self._one(connection, self.behavior)
        except BaseException as exc:
            idle_stream_connection = (
                self.behavior == "stream"
                and (
                    isinstance(exc, socket.timeout)
                    or (
                        isinstance(exc, ConformanceFailure)
                        and "closed before sending" in str(exc)
                    )
                )
            )
            if not self.stop_event.is_set() and not self.done.is_set() and not idle_stream_connection:
                self.error = exc
                self.done.set()

    def _no_write(self, connection: socket.socket) -> None:
        connection.settimeout(2)
        try:
            data = connection.recv(1)
        except socket.timeout:
            data = b""
        if data:
            self.bytes_received.set()
            raise ConformanceFailure(
                "provider-authority denial wrote bytes before returning"
            )
        self.done.set()

    def _request_shape(self, connection: socket.socket) -> None:
        request = self._read_request(connection)
        if request.get("cmd") == "identify":
            self._send_json(connection, self._identify_response(request))
            try:
                request = self._read_request(connection)
            except socket.timeout:
                self.stop_event.wait(2)
                return
            except ConformanceFailure as exc:
                if "closed before sending" not in str(exc):
                    raise
                self.stop_event.wait(2)
                return

        actual = {key: value for key, value in request.items() if key != "id"}
        expected = self.spec.get("expect_request")
        if actual != expected:
            raise ConformanceFailure(
                "typed request shape mismatch\n"
                f"expected: {json.dumps(expected, sort_keys=True)}\n"
                f"actual: {json.dumps(actual, sort_keys=True)}"
            )
        self._send_json(
            connection,
            {"id": request.get("id"), "ok": True, "data": {}},
        )
        self.done.set()

    def _read_request(self, connection: socket.socket) -> dict[str, Any]:
        connection.settimeout(2)
        data = bytearray()
        while b"\n" not in data:
            chunk = connection.recv(4096)
            if not chunk:
                raise ConformanceFailure("adapter closed before sending a complete request")
            data.extend(chunk)
            if len(data) > 1_048_576:
                raise ConformanceFailure("adapter request exceeded 1 MiB")
        line, _, _ = data.partition(b"\n")
        value = json.loads(line)
        if not isinstance(value, dict):
            raise ConformanceFailure("wire request is not an object")
        self.requests.append(value)
        return value

    def _send_json(self, connection: socket.socket, value: Mapping[str, Any]) -> None:
        wire = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode() + b"\n"
        chunks = [int(size) for size in self.spec.get("chunks", [])]
        if not chunks:
            connection.sendall(wire)
            return
        offset = 0
        index = 0
        while offset < len(wire):
            size = chunks[index % len(chunks)]
            connection.sendall(wire[offset : offset + size])
            offset += size
            index += 1
            time.sleep(0.001)

    def _identify_data(self) -> dict[str, Any]:
        data = {
            "app": "cmux-tui",
            "version": "0.0.0-conformance",
            "build_commit": None,
            "ghostty_commit": None,
            "protocol": 12,
            "capabilities": [
                "attach-initial-size",
                "provider-managed-workspace-authority-v2",
                "surface-subscribe-filter",
                "workspace-registry-v1",
            ],
            "session": "conformance",
            "pid": 4242,
            "registry_id": "registry-conformance",
            "generation": "generation-conformance",
            "workspace_revision": 0,
            "terminal_revision": UINT64_MAX,
            "daemon_handoff": 1,
        }
        capabilities_presence = self.spec.get("capabilities_presence")
        if capabilities_presence == "omitted":
            data.pop("capabilities")
        elif capabilities_presence == "null":
            data["capabilities"] = None
        elif capabilities_presence == "value":
            data["capabilities"] = ["conformance-capability"]
        elif capabilities_presence is not None:
            raise ConformanceFailure(
                f"unknown capabilities presence {capabilities_presence!r}"
            )
        return data

    def _identify_response(self, request: Mapping[str, Any]) -> dict[str, Any]:
        return {"id": request.get("id"), "ok": True, "data": self._identify_data()}

    def _one(self, connection: socket.socket, behavior: str) -> None:
        request = self._read_request(connection)
        if request.get("cmd") == "identify" and behavior in ("stream",):
            self._send_json(connection, self._identify_response(request))
            try:
                request = self._read_request(connection)
            except socket.timeout:
                # Some SDKs negotiate on their command connection and open the
                # stream on a second socket. Others reuse this connection.
                self.stop_event.wait(2)
                return
            except ConformanceFailure as exc:
                if "closed before sending" not in str(exc):
                    raise
                self.stop_event.wait(2)
                return
        if request.get("cmd") == "identify" and behavior == "terminal-placement":
            self._send_json(connection, self._identify_response(request))
            request = self._read_request(connection)
        if behavior == "identify":
            self._send_json(connection, self._identify_response(request))
        elif behavior == "oversized-identify":
            data = self._identify_data()
            data["version"] = "x" * int(self.spec.get("response_bytes", 4096))
            self._send_json(connection, {"id": request.get("id"), "ok": True, "data": data})
        elif behavior == "invalid-utf8":
            connection.sendall(b'{"id":1,"ok":true,"data":{"app":"cmux-\\xff"}}\n')
        elif behavior == "timeout":
            self.stop_event.wait(int(self.spec.get("hold_ms", 500)) / 1000)
        elif behavior == "terminal-placement":
            if request.get("cmd") != "create-terminal":
                raise ConformanceFailure(
                    f"expected create-terminal command, got {request!r}"
                )
            data = {
                "surface": 1,
                "pane": 2,
                "screen": 3,
                "workspace": 4,
                "terminal_id": "0123456789abcdef0123456789abcdef",
                "terminal_incarnation": None,
                "generation": "generation-conformance",
                "key": "workspace-key",
                "registry_id": "registry-conformance",
                "replayed": False,
                "terminal_revision": 5,
                "exit": None,
                "already_exited": False,
            }
            if not self.spec.get("omit_lifecycle", False):
                data["lifecycle"] = self.spec.get("lifecycle")
            self._send_json(
                connection,
                {"id": request.get("id"), "ok": True, "data": data},
            )
        elif behavior == "stream":
            self._stream(connection, request)
            return
        else:
            raise ConformanceFailure(f"unknown fake server behavior {behavior!r}")
        self.done.set()

    def _stream(self, connection: socket.socket, request: Mapping[str, Any]) -> None:
        if request.get("cmd") not in ("subscribe", "attach-surface"):
            raise ConformanceFailure(f"expected stream command, got {request!r}")
        for event in self.spec.get("before_ack", []):
            self._send_json(connection, event)
        self._send_json(connection, {"id": request.get("id"), "ok": True, "data": {}})
        for event in self.spec.get("after_ack", []):
            self._send_json(connection, event)
        if self.spec.get("close_after_send"):
            self.done.set()
            return
        self.stop_event.wait(int(self.spec.get("hold_ms", 100)) / 1000)
        self.done.set()

    def _authority(self, connection: socket.socket) -> None:
        request = self._read_request(connection)
        if request.get("cmd") == "identify":
            self._send_json(connection, self._identify_response(request))
            request = self._read_request(connection)
        command = request.get("cmd")
        if command == "ping":
            data: dict[str, Any] = {
                "ok": True,
                "version": "0.0.0-conformance",
                "build_commit": None,
                "ghostty_commit": None,
                "protocol": 12,
            }
        elif command in (
            "browser-back",
            "pairing-response",
            "mark-workspaces-provider-managed",
        ):
            data = {}
        else:
            raise ConformanceFailure(f"unexpected authority probe command {command!r}")
        self._send_json(connection, {"id": request.get("id"), "ok": True, "data": data})
        self.done.set()


@dataclasses.dataclass
class HeadlessServer:
    process: subprocess.Popen[str]
    socket_path: str
    log: list[str]
    directory: Path


def start_headless_server(binary: Path) -> HeadlessServer:
    session = f"sdk-conformance-{os.getpid()}-{time.time_ns()}"
    directory = Path(tempfile.mkdtemp(prefix="cmux-sdk-real-"))
    socket_path = directory / "cmux.sock"
    process = subprocess.Popen(
        [
            str(binary),
            "--headless",
            "--ephemeral",
            "--socket",
            str(socket_path),
            "--session",
            session,
        ],
        cwd=MUX_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + 15
    lines: list[str] = []
    try:
        while time.monotonic() < deadline:
            for key, _ in selector.select(timeout=0.1):
                line = key.fileobj.readline()
                if line:
                    lines.append(line.rstrip())
            if socket_path.exists():
                break
            if process.poll() is not None:
                raise ConformanceFailure(
                    f"headless server exited before socket path: {'; '.join(lines)}"
                )
    finally:
        selector.close()
    if not socket_path.exists():
        stop_headless_server(process)
        shutil.rmtree(directory, ignore_errors=True)
        raise ConformanceFailure(
            f"timed out waiting for headless server socket: {'; '.join(lines)}"
        )
    return HeadlessServer(process, str(socket_path), lines, directory)


def stop_headless_server(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def partial_match(actual: Any, expected: Any) -> bool:
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(
            key in actual and partial_match(actual[key], value)
            for key, value in expected.items()
        )
    if isinstance(expected, list):
        return (
            isinstance(actual, list)
            and len(actual) >= len(expected)
            and all(partial_match(actual[index], value) for index, value in enumerate(expected))
        )
    return actual == expected


def assert_case_response(case: Mapping[str, Any], response: Mapping[str, Any]) -> None:
    expected_error = case.get("expect_error")
    if expected_error is not None:
        if response.get("ok") is not False:
            raise ConformanceFailure(f"expected {expected_error} error, got {response}")
        error = response.get("error")
        if not isinstance(error, dict) or error.get("kind") != expected_error:
            raise ConformanceFailure(f"expected {expected_error} error, got {response}")
        return
    expected = case["expect"]
    comparable = {key: value for key, value in response.items() if key not in ("id", "contract_version")}
    if not partial_match(comparable, expected):
        raise ConformanceFailure(
            "response mismatch\n"
            f"expected subset: {json.dumps(expected, sort_keys=True)}\n"
            f"actual: {json.dumps(comparable, sort_keys=True)}"
        )


def run_metadata_audit(adapter: Adapter) -> None:
    response = adapter.request({"contract_version": 1, "id": "metadata", "op": "metadata"})
    if response.get("ok") is not True:
        raise ConformanceFailure(f"metadata operation failed: {response}")
    value = response.get("value")
    if not isinstance(value, dict):
        raise ConformanceFailure("metadata value must be an object")
    commands = value.get("commands")
    events = value.get("events")
    if not isinstance(commands, list) or not isinstance(events, list):
        raise ConformanceFailure("metadata commands/events must be arrays")
    actual_commands = {item["name"] for item in commands if isinstance(item, dict) and "name" in item}
    actual_events = {item["name"] for item in events if isinstance(item, dict) and "name" in item}
    authorities = {
        item.get("authority")
        for item in commands
        if isinstance(item, dict) and item.get("authority")
    }
    streams = {
        stream
        for item in events
        if isinstance(item, dict)
        for stream in item.get("streams", [])
    }
    for catalog_path, source_commit, protocol in RAW_CATALOGS:
        catalog = json.loads(catalog_path.read_text())
        if (
            catalog.get("source_commit") != source_commit
            or catalog.get("protocol") != protocol
        ):
            raise ConformanceFailure(
                f"raw catalog is not the frozen protocol-{protocol} snapshot"
            )
        expected_commands = set(catalog["commands"])
        expected_events = set(catalog["events"])
        if not expected_commands.issubset(actual_commands):
            raise ConformanceFailure(
                f"command metadata is missing frozen protocol-{protocol} operations: "
                f"{sorted(expected_commands - actual_commands)}"
            )
        if not expected_events.issubset(actual_events):
            raise ConformanceFailure(
                f"event metadata is missing frozen protocol-{protocol} events: "
                f"{sorted(expected_events - actual_events)}"
            )
        expected_authorities = set(catalog["authorities"])
        if not expected_authorities.issubset(authorities):
            raise ConformanceFailure(
                f"protocol-{protocol} authority metadata is missing frozen authorities: "
                f"{sorted(expected_authorities - authorities)}"
            )
        expected_streams = set(catalog["streams"])
        if not expected_streams.issubset(streams):
            raise ConformanceFailure(
                f"protocol-{protocol} event stream metadata is missing frozen streams: "
                f"{sorted(expected_streams - streams)}"
            )


def run_fake_case(adapter: Adapter, case: Mapping[str, Any], ordinal: int) -> None:
    with FakeServer(case["server"]) as server:
        payload = dict(case["adapter"])
        payload.update(
            {
                "contract_version": 1,
                "id": f"fake-{ordinal}",
                "socket_path": str(server.socket_path),
            }
        )
        timeout = max(10.0, float(payload.get("deadline_ms", payload.get("timeout_ms", 1000))) / 1000 + 3)
        response = adapter.request(payload, timeout=timeout)
        assert_case_response(case, response)
        if server.behavior == "no-write":
            if server.connected.wait(timeout=0.5) and not server.done.wait(timeout=2):
                raise ConformanceFailure(
                    "default client left its no-write authority probe connected"
                )
            if server.bytes_received.is_set():
                raise ConformanceFailure(
                    "default client wrote bytes for a denied provider-authority command"
                )
            return
        if not server.done.wait(timeout=2):
            raise ConformanceFailure("fake server did not finish")


def run_real_cases(adapter: Adapter, cases: Sequence[Mapping[str, Any]], binary: Path) -> None:
    server = start_headless_server(binary)
    try:
        for ordinal, case in enumerate(cases):
            payload = dict(case["adapter"])
            payload.update(
                {
                    "contract_version": 1,
                    "id": f"real-{ordinal}",
                    "socket_path": server.socket_path,
                }
            )
            response = adapter.request(payload, timeout=15)
            assert_case_response(case, response)
    finally:
        stop_headless_server(server.process)
        shutil.rmtree(server.directory, ignore_errors=True)


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--language",
        action="append",
        choices=LANGUAGES,
        help="language to test; repeat to select multiple (default: all)",
    )
    parser.add_argument("--fake-only", action="store_true", help="skip the real headless server smoke")
    parser.add_argument("--real-only", action="store_true", help="skip deterministic fake-server cases")
    parser.add_argument(
        "--require",
        default="",
        help="comma-separated languages whose missing toolchain is a failure",
    )
    parser.add_argument(
        "--cmux-tui-bin",
        type=Path,
        default=None,
        help="prebuilt cmux-tui binary (default: cmux-tui/target/debug/cmux-tui)",
    )
    parser.add_argument("--no-build", action="store_true", help="do not build adapters or cmux-tui")
    parser.add_argument(
        "--no-codegen-check",
        action="store_true",
        help="skip generated SDK drift detection (diagnostics only)",
    )
    args = parser.parse_args(argv)
    if args.fake_only and args.real_only:
        parser.error("--fake-only and --real-only are mutually exclusive")
    return args


def ensure_tui_binary(path: Path, no_build: bool) -> None:
    if path.exists():
        return
    if no_build:
        raise ConformanceFailure(f"cmux-tui binary does not exist: {path}")
    result = subprocess.run(
        ("cargo", "build", "-p", "cmux-tui", "--locked"),
        cwd=MUX_DIR,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=600,
        check=False,
    )
    if result.returncode != 0:
        raise ConformanceFailure(f"cmux-tui build failed:\n{result.stdout}")
    if not path.exists():
        raise ConformanceFailure(f"cmux-tui build succeeded but binary is missing: {path}")


def check_generated_sdks() -> None:
    command = (
        sys.executable,
        str(BINDINGS / "codegen" / "generate.py"),
        "--check",
    )
    result = subprocess.run(
        command,
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=300,
        check=False,
    )
    if result.returncode != 0:
        raise ConformanceFailure(f"generated SDK drift:\n{result.stdout}")


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    selected = tuple(args.language or LANGUAGES)
    required = {name for name in args.require.split(",") if name}
    fixtures = json.loads(FIXTURES.read_text())
    if fixtures.get("contract_version") != 1:
        raise SystemExit("fixtures contract_version must be 1")
    specs = adapter_specs()
    binary = (args.cmux_tui_bin or (MUX_DIR / "target" / "debug" / "cmux-tui")).resolve()
    if not args.no_codegen_check:
        try:
            check_generated_sdks()
        except Exception as exc:
            print(f"FAIL codegen-check: {exc}")
            return 1
    if not args.fake_only:
        try:
            ensure_tui_binary(binary, args.no_build)
        except Exception as exc:
            print(f"FAIL server-build: {exc}")
            return 1

    results: list[CaseResult] = []
    for language in selected:
        adapter = Adapter(specs[language])
        try:
            if not args.no_build:
                adapter.build()
            else:
                adapter.check_tools()
        except ToolchainMissing as exc:
            status = "FAIL" if language in required else "SKIP"
            results.append(CaseResult(language, "adapter-build", status, str(exc)))
            continue
        except Exception as exc:
            results.append(CaseResult(language, "adapter-build", "FAIL", str(exc)))
            continue

        try:
            run_metadata_audit(adapter)
        except Exception as exc:
            results.append(CaseResult(language, "metadata-coverage", "FAIL", str(exc)))
        else:
            results.append(CaseResult(language, "metadata-coverage", "PASS"))

        if not args.real_only:
            for ordinal, case in enumerate(fixtures["fake_cases"]):
                try:
                    run_fake_case(adapter, case, ordinal)
                except Exception as exc:
                    results.append(CaseResult(language, case["name"], "FAIL", str(exc)))
                else:
                    results.append(CaseResult(language, case["name"], "PASS"))

        if not args.fake_only:
            for case in fixtures["real_cases"]:
                try:
                    run_real_cases(adapter, [case], binary)
                except Exception as exc:
                    results.append(CaseResult(language, case["name"], "FAIL", str(exc)))
                else:
                    results.append(CaseResult(language, case["name"], "PASS"))

    for result in results:
        suffix = f": {result.detail}" if result.detail else ""
        print(f"{result.status} {result.language}/{result.name}{suffix}")
    passed = sum(result.status == "PASS" for result in results)
    skipped = sum(result.status == "SKIP" for result in results)
    failed = sum(result.status == "FAIL" for result in results)
    print(f"conformance: {passed} passed, {skipped} skipped, {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
