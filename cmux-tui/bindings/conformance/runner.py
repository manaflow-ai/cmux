#!/usr/bin/env python3
"""Cross-language conformance for the handwritten cmux resource SDKs."""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
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
BINDINGS = HERE.parent
MUX_DIR = BINDINGS.parent
ROOT = MUX_DIR.parent
FIXTURES = HERE / "fixtures.json"
CATALOG = MUX_DIR / "spec" / "resource-operations-v1.json"
BUILD = HERE / ".build" / "resource-v1"
LANGUAGES = ("python", "typescript", "rust", "go", "java", "cpp", "zig")
PROTOCOL = "cmux.protocol/1"
MAX_REQUEST_BYTES = 4 * 1024 * 1024
MAX_STREAM_MESSAGES = 256
MAX_STREAM_BYTES = 16 * 1024 * 1024
OPAQUE_STREAM = re.compile(r"^stream_[0-9a-f]{32}$")


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
            (str(BUILD / "rust" / "debug" / "cmux-resource-conformance-rust"),),
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
                    str(BUILD / "go" / "cmux-resource-conformance-go"),
                    str(adapters / "go" / "main.go"),
                ),
            ),
            (str(BUILD / "go" / "cmux-resource-conformance-go"),),
            BINDINGS / "go",
        ),
        "java": AdapterSpec(
            "java",
            ("java", "javac"),
            (("bash", str(adapters / "java" / "build.sh"), str(BUILD / "java")),),
            (
                "java",
                "-Xms16m",
                "-Xmx192m",
                "-cp",
                str(BUILD / "java"),
                "com.cmux.conformance.ResourceAdapter",
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
                ("cmake", "--build", str(BUILD / "cpp"), "--parallel"),
            ),
            (str(BUILD / "cpp" / "cmux-resource-conformance-cpp"),),
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
            (str(BUILD / "zig" / "bin" / "cmux-resource-conformance-zig"),),
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
                timeout=420,
                check=False,
            )
            if result.returncode != 0:
                raise ConformanceFailure(
                    f"adapter build failed ({' '.join(command)}):\n{result.stdout}"
                )

    def request(
        self,
        payload: Mapping[str, Any],
        *,
        timeout: float = 45.0,
    ) -> dict[str, Any]:
        process = subprocess.Popen(
            self.spec.command,
            cwd=self.spec.cwd,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        request_line = json.dumps(
            payload, separators=(",", ":"), ensure_ascii=False
        ) + "\n"
        try:
            stdout, stderr = process.communicate(request_line, timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = process.communicate()
            raise ConformanceFailure(
                f"adapter timed out; stdout={stdout!r}; stderr={stderr!r}"
            )
        if process.returncode != 0:
            raise ConformanceFailure(
                f"adapter exited {process.returncode}; "
                f"stdout={stdout!r}; stderr={stderr!r}"
            )
        lines = [line for line in stdout.splitlines() if line.strip()]
        if len(lines) != 1:
            raise ConformanceFailure(
                "adapter must return exactly one JSON line; "
                f"stdout={stdout!r}; stderr={stderr!r}"
            )
        try:
            response = json.loads(lines[0])
        except json.JSONDecodeError as error:
            raise ConformanceFailure(
                f"adapter returned invalid JSON: {error}; stdout={stdout!r}"
            ) from error
        if not isinstance(response, dict):
            raise ConformanceFailure("adapter response must be an object")
        if response.get("contract_version") != 2:
            raise ConformanceFailure(
                f"adapter contract_version must be 2, got "
                f"{response.get('contract_version')!r}"
            )
        if response.get("id") != payload.get("id"):
            raise ConformanceFailure(
                f"adapter response id {response.get('id')!r} does not match "
                f"{payload.get('id')!r}"
            )
        return response


@dataclasses.dataclass
class _Connection:
    socket: socket.socket
    writer_lock: threading.Lock = dataclasses.field(default_factory=threading.Lock)


class ResourceV1Server:
    """Deterministic Unix JSONL peer that validates public request envelopes."""

    def __init__(
        self,
        behavior: str,
        constants: Mapping[str, str],
        operations: Mapping[str, Mapping[str, Any]],
    ) -> None:
        self.behavior = behavior
        self.constants = dict(constants)
        self.operations = operations
        self.directory = Path(tempfile.mkdtemp(prefix="cmux-resource-conformance-"))
        self.socket_path = self.directory / "server.sock"
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(self.socket_path))
        self.listener.listen(16)
        self.listener.settimeout(0.1)
        self.stop_event = threading.Event()
        self.error: BaseException | None = None
        self.requests: list[dict[str, Any]] = []
        self.connections: list[_Connection] = []
        self.connection_threads: list[threading.Thread] = []
        self.sender_threads: list[threading.Thread] = []
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.stream_opens = 0
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "ResourceV1Server":
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
        for connection in list(self.connections):
            try:
                connection.socket.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.socket.close()
        self.thread.join(timeout=3)
        for thread in self.connection_threads + self.sender_threads:
            thread.join(timeout=3)
        self.listener.close()
        self.socket_path.unlink(missing_ok=True)
        try:
            self.directory.rmdir()
        except OSError:
            pass
        if exc is None and self.error is not None:
            raise ConformanceFailure(f"fake server failed: {self.error}") from self.error

    def _serve(self) -> None:
        try:
            while not self.stop_event.is_set():
                try:
                    raw, _ = self.listener.accept()
                except socket.timeout:
                    continue
                connection = _Connection(raw)
                with self.lock:
                    self.connections.append(connection)
                thread = threading.Thread(
                    target=self._handle_connection,
                    args=(connection,),
                    daemon=True,
                )
                self.connection_threads.append(thread)
                thread.start()
        except BaseException as error:
            if not self.stop_event.is_set():
                self._fail(error)

    def _handle_connection(self, connection: _Connection) -> None:
        try:
            with connection.socket:
                reader = connection.socket.makefile("rb")
                while not self.stop_event.is_set():
                    line = reader.readline(MAX_REQUEST_BYTES + 2)
                    if not line:
                        break
                    if len(line) > MAX_REQUEST_BYTES + 1 or not line.endswith(b"\n"):
                        raise ConformanceFailure("request exceeded 4 MiB or lacked JSONL newline")
                    try:
                        request = json.loads(line)
                    except (UnicodeDecodeError, json.JSONDecodeError) as error:
                        raise ConformanceFailure(f"invalid request JSONL: {error}") from error
                    self._validate_base(request)
                    with self.changed:
                        self.requests.append(request)
                        self.changed.notify_all()
                    self._dispatch(connection, request)
        except (BrokenPipeError, ConnectionResetError, OSError) as error:
            if not self.stop_event.is_set():
                self._fail(error)
        except BaseException as error:
            if not self.stop_event.is_set():
                self._fail(error)

    def _fail(self, error: BaseException) -> None:
        with self.changed:
            if self.error is None:
                self.error = error
            self.changed.notify_all()

    def _validate_base(self, request: Any) -> None:
        if not isinstance(request, dict):
            raise ConformanceFailure("request envelope must be an object")
        operation = request.get("operation")
        if operation not in self.operations:
            raise ConformanceFailure(f"unknown public operation {operation!r}")
        op_class = self.operations[operation]["class"]
        allowed = {"protocol", "type", "id", "operation", "params"}
        if op_class == "mutation":
            allowed.add("idempotency_key")
        if set(request) != allowed:
            raise ConformanceFailure(
                f"{operation} envelope keys {sorted(request)} != {sorted(allowed)}"
            )
        if request["protocol"] != PROTOCOL or request["type"] != "request":
            raise ConformanceFailure("request used the wrong protocol or envelope type")
        request_id = request["id"]
        if not isinstance(request_id, str) or not 1 <= len(request_id) <= 128:
            raise ConformanceFailure("request id must be a bounded nonempty string")
        if not isinstance(request["params"], dict):
            raise ConformanceFailure("request params must be an object")
        if op_class == "mutation":
            key = request["idempotency_key"]
            if not isinstance(key, str) or not 1 <= len(key) <= 128:
                raise ConformanceFailure("mutation key must be a bounded nonempty string")

    def _dispatch(self, connection: _Connection, request: Mapping[str, Any]) -> None:
        operation = request["operation"]
        if operation == "session.ping":
            self._expect_params(
                request,
                {
                    "machine": "current",
                    "session": self.constants["session"],
                },
            )
            self._ok(
                connection,
                request,
                {
                    "alive": True,
                    "cursor": {
                        "generation": self.constants["generation"],
                        "revision": self.constants["revision"],
                    },
                },
            )
            return
        if operation == "workspace.rename":
            self._expect_mutation(request)
            self._dispatch_mutation(connection, request)
            return
        if operation == "session.events":
            self._expect_stream_open(request)
            self._dispatch_stream_open(connection, request)
            return
        if operation == "stream.cancel":
            self._expect_stream_cancel(request)
            self._dispatch_cancel(connection, request)
            return
        raise ConformanceFailure(
            f"behavior {self.behavior} did not expect operation {operation}"
        )

    def _expect_params(
        self, request: Mapping[str, Any], expected: Mapping[str, Any]
    ) -> None:
        if request["params"] != expected:
            raise ConformanceFailure(
                "exact params mismatch\n"
                f"expected: {json.dumps(expected, sort_keys=True, ensure_ascii=False)}\n"
                f"actual: {json.dumps(request['params'], sort_keys=True, ensure_ascii=False)}"
            )

    def _expect_mutation(self, request: Mapping[str, Any]) -> None:
        self._expect_params(
            request,
            {
                "machine": "current",
                "session": self.constants["session"],
                "workspace": self.constants["workspace"],
                "name": self.constants["name"],
                "expected_revision": self.constants["revision"],
            },
        )
        if request["idempotency_key"] != self.constants["idempotency_key"]:
            raise ConformanceFailure("adapter changed the explicit idempotency key")

    def _expect_stream_open(self, request: Mapping[str, Any]) -> None:
        params = request["params"]
        if set(params) != {"machine", "session", "stream_id"}:
            raise ConformanceFailure(
                f"session.events params must be exact, got {sorted(params)}"
            )
        if (
            params["machine"] != "current"
            or params["session"] != self.constants["session"]
            or not isinstance(params["stream_id"], str)
            or OPAQUE_STREAM.fullmatch(params["stream_id"]) is None
        ):
            raise ConformanceFailure(f"invalid session.events routing: {params!r}")

    def _expect_stream_cancel(self, request: Mapping[str, Any]) -> None:
        params = request["params"]
        if set(params) != {"machine", "session", "stream"}:
            raise ConformanceFailure(
                f"stream.cancel params must be exact, got {sorted(params)}"
            )
        if (
            params["machine"] != "current"
            or params["session"] != self.constants["session"]
            or not isinstance(params["stream"], str)
            or OPAQUE_STREAM.fullmatch(params["stream"]) is None
        ):
            raise ConformanceFailure(f"invalid stream.cancel routing: {params!r}")

    def _dispatch_mutation(
        self, connection: _Connection, request: Mapping[str, Any]
    ) -> None:
        if self.behavior == "mutation-replay":
            prior = sum(
                item["operation"] == "workspace.rename" for item in self.requests
            )
            self._ok(connection, request, self._mutation_result(prior > 1))
            return
        errors = {
            "mutation-indeterminate": {
                "code": "mutation.indeterminate",
                "message": "external effect outcome is unknown",
                "details": {
                    "idempotency_key": self.constants["idempotency_key"],
                    "operation": "workspace.rename",
                    "recovery": "inspect_state_then_retry_with_new_key",
                },
                "retryable": False,
            },
            "revision-conflict": {
                "code": "revision.conflict",
                "message": "expected revision is stale",
                "details": {
                    "expected": self.constants["revision"],
                    "actual": "42",
                },
                "retryable": True,
            },
            "selector-ambiguous": {
                "code": "selector.ambiguous",
                "message": "more than one workspace is named api",
                "details": {
                    "candidates": [
                        self.constants["candidate_a"],
                        self.constants["candidate_b"],
                    ]
                },
                "retryable": False,
            },
        }
        error = errors.get(self.behavior)
        if error is None:
            raise ConformanceFailure(
                f"behavior {self.behavior} cannot handle workspace.rename"
            )
        self._error(connection, request, error)

    def _mutation_result(self, replayed: bool) -> dict[str, Any]:
        return {
            "value": {
                "id": self.constants["workspace"],
                "session_id": self.constants["session"],
                "name": self.constants["name"],
                "index": 7,
                "focused": False,
            },
            "generation": self.constants["generation"],
            "revision": self.constants["revision"],
            "replayed": replayed,
        }

    def _dispatch_stream_open(
        self, connection: _Connection, request: Mapping[str, Any]
    ) -> None:
        stream_id = request["params"]["stream_id"]
        with self.lock:
            self.stream_opens += 1
            index = self.stream_opens
        self._ok(
            connection,
            request,
            {
                "stream_id": stream_id,
                "cursor": {
                    "generation": self.constants["generation"],
                    "revision": "0",
                },
            },
        )
        if self.behavior == "stream-unknown":
            self._stream_item(
                connection,
                stream_id,
                self.constants["revision"],
                {
                    "kind": "future.session.widget",
                    "payload": {
                        "label": "kept",
                        "revision": self.constants["revision"],
                    },
                },
                revision=self.constants["revision"],
            )
            self._stream_end(connection, stream_id, "completed")
            return
        if self.behavior == "stream-cancel":
            self._stream_item(
                connection,
                stream_id,
                "0",
                {"kind": "future.queued", "payload": {"must_be_purged": True}},
                revision="0",
            )
            return
        if self.behavior in {
            "stream-overflow-messages",
            "stream-overflow-bytes",
        }:
            sender = threading.Thread(
                target=self._send_overflow,
                args=(connection, stream_id, index),
                daemon=True,
            )
            self.sender_threads.append(sender)
            sender.start()
            return
        raise ConformanceFailure(
            f"behavior {self.behavior} cannot handle session.events"
        )

    def _send_overflow(
        self, connection: _Connection, stream_id: str, index: int
    ) -> None:
        try:
            if index > 1:
                self._stream_item(
                    connection,
                    stream_id,
                    "0",
                    {
                        "kind": "future.after-overflow",
                        "payload": {"stream_is_independent": True},
                    },
                    revision="0",
                )
                self._stream_end(connection, stream_id, "completed")
                return
            if self.behavior == "stream-overflow-messages":
                count = MAX_STREAM_MESSAGES + 1
                payload = {"kind": "future.bulk", "payload": {"padding": "x"}}
            else:
                count = 17
                payload = {
                    "kind": "future.bulk",
                    "payload": {"padding": "x" * 1_048_000},
                }
            for sequence in range(count):
                if self.stop_event.is_set():
                    return
                self._stream_item(
                    connection,
                    stream_id,
                    str(sequence),
                    payload,
                    revision=str(sequence),
                )
            self._stream_end(
                connection,
                stream_id,
                "gap",
                cursor={
                    "generation": self.constants["generation"],
                    "revision": str(count),
                },
                recovery="open a fresh stream to receive a new snapshot",
            )
        except (BrokenPipeError, ConnectionResetError, OSError) as error:
            if not self.stop_event.is_set():
                self._fail(error)
        except BaseException as error:
            self._fail(error)

    def _dispatch_cancel(
        self, connection: _Connection, request: Mapping[str, Any]
    ) -> None:
        stream_id = request["params"]["stream"]
        if self.behavior == "stream-cancel":
            # The contract requires the terminal envelope to be queued first.
            self._stream_end(connection, stream_id, "canceled")
        self._ok(connection, request, {})

    def _ok(
        self,
        connection: _Connection,
        request: Mapping[str, Any],
        result: Any,
    ) -> None:
        self._send(
            connection,
            {
                "protocol": PROTOCOL,
                "type": "response",
                "id": request["id"],
                "ok": True,
                "result": result,
            },
        )

    def _error(
        self,
        connection: _Connection,
        request: Mapping[str, Any],
        error: Mapping[str, Any],
    ) -> None:
        self._send(
            connection,
            {
                "protocol": PROTOCOL,
                "type": "response",
                "id": request["id"],
                "ok": False,
                "error": error,
            },
        )

    def _stream_item(
        self,
        connection: _Connection,
        stream_id: str,
        sequence: str,
        item: Any,
        *,
        revision: str,
    ) -> None:
        self._send(
            connection,
            {
                "protocol": PROTOCOL,
                "type": "stream_item",
                "stream_id": stream_id,
                "sequence": sequence,
                "cursor": {
                    "generation": self.constants["generation"],
                    "revision": revision,
                },
                "item": item,
            },
        )

    def _stream_end(
        self,
        connection: _Connection,
        stream_id: str,
        reason: str,
        *,
        cursor: Mapping[str, str] | None = None,
        recovery: str | None = None,
    ) -> None:
        envelope: dict[str, Any] = {
            "protocol": PROTOCOL,
            "type": "stream_end",
            "stream_id": stream_id,
            "reason": reason,
        }
        if cursor is not None:
            envelope["cursor"] = dict(cursor)
        if recovery is not None:
            envelope["recovery"] = recovery
        self._send(connection, envelope)

    def _send(self, connection: _Connection, value: Mapping[str, Any]) -> None:
        encoded = json.dumps(
            value, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        if len(encoded) > MAX_STREAM_BYTES:
            raise ConformanceFailure(
                f"fake response frame exceeded {MAX_STREAM_BYTES} bytes"
            )
        with connection.writer_lock:
            connection.socket.sendall(encoded + b"\n")

    def wait_for_requests(self, count: int, timeout: float = 2.0) -> None:
        deadline = time.monotonic() + timeout
        with self.changed:
            while len(self.requests) < count and self.error is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                self.changed.wait(remaining)
        if self.error is not None:
            raise ConformanceFailure(f"fake server failed: {self.error}") from self.error

    def assert_complete(self) -> None:
        expected = {
            "read": {"session.ping": 1},
            "mutation-replay": {"workspace.rename": 2},
            "mutation-indeterminate": {"workspace.rename": 1},
            "revision-conflict": {"workspace.rename": 1},
            "selector-ambiguous": {"workspace.rename": 1},
            "stream-unknown": {"session.events": 1},
            "stream-cancel": {"session.events": 1, "stream.cancel": 1},
        }
        if self.behavior in {
            "stream-overflow-messages",
            "stream-overflow-bytes",
        }:
            self.wait_for_requests(3, timeout=3.0)
            counts = self._request_counts()
            if counts.get("session.events") != 2:
                raise ConformanceFailure(
                    f"overflow must open two independent streams, got {counts}"
                )
            if counts.get("session.ping") != 1:
                raise ConformanceFailure(
                    f"overflow must leave control reads alive, got {counts}"
                )
            return
        wanted = expected[self.behavior]
        self.wait_for_requests(sum(wanted.values()))
        counts = self._request_counts()
        if counts != wanted:
            raise ConformanceFailure(
                f"{self.behavior} request counts {counts} != {wanted}"
            )

    def _request_counts(self) -> dict[str, int]:
        result: dict[str, int] = {}
        with self.lock:
            requests = list(self.requests)
        for request in requests:
            operation = request["operation"]
            result[operation] = result.get(operation, 0) + 1
        return result


def load_contract() -> tuple[dict[str, Any], dict[str, Any]]:
    fixtures = json.loads(FIXTURES.read_text())
    catalog = json.loads(CATALOG.read_text())
    if fixtures.get("contract_version") != 2:
        raise ConformanceFailure("fixture adapter contract must be version 2")
    if fixtures.get("protocol") != PROTOCOL:
        raise ConformanceFailure("fixtures target the wrong protocol")
    if catalog.get("protocol") != PROTOCOL:
        raise ConformanceFailure("operation catalog targets the wrong protocol")
    operations = catalog.get("operations")
    if not isinstance(operations, dict) or len(operations) != 122:
        raise ConformanceFailure(
            f"expected 122 transported operations, got "
            f"{len(operations) if isinstance(operations, dict) else 'invalid'}"
        )
    return fixtures, catalog


def assert_response(actual: Mapping[str, Any], expected: Mapping[str, Any]) -> None:
    comparable = {
        "ok": actual.get("ok"),
        **({"value": actual.get("value")} if "value" in actual else {}),
        **({"error": actual.get("error")} if "error" in actual else {}),
    }
    if comparable != expected:
        raise ConformanceFailure(
            "adapter result mismatch\n"
            f"expected: {json.dumps(expected, indent=2, ensure_ascii=False, sort_keys=True)}\n"
            f"actual: {json.dumps(comparable, indent=2, ensure_ascii=False, sort_keys=True)}"
        )


def run_fake_case(
    adapter: Adapter,
    case: Mapping[str, Any],
    constants: Mapping[str, str],
    operations: Mapping[str, Mapping[str, Any]],
) -> None:
    payload = {
        "contract_version": 2,
        "id": case["name"],
        **case["adapter"],
        "constants": constants,
    }
    server_spec = case.get("server")
    if server_spec is None:
        response = adapter.request(payload)
        assert_response(response, case["expect"])
        return
    with ResourceV1Server(
        str(server_spec["behavior"]), constants, operations
    ) as server:
        payload["socket_path"] = str(server.socket_path)
        response = adapter.request(
            payload,
            timeout=75.0 if "overflow" in case["name"] else 20.0,
        )
        server.assert_complete()
        assert_response(response, case["expect"])


def run_live_case(adapter: Adapter, binary: Path, constants: Mapping[str, str]) -> None:
    if not binary.exists():
        raise ConformanceFailure(f"cmux-tui binary does not exist: {binary}")
    directory = Path(tempfile.mkdtemp(prefix="cmux-resource-live-"))
    socket_path = directory / "session.sock"
    command = (
        str(binary),
        "--headless",
        "--ephemeral",
        "--session",
        "resource-conformance",
        "--socket",
        str(socket_path),
    )
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if socket_path.exists():
                break
            if process.poll() is not None:
                output = process.stdout.read() if process.stdout else ""
                raise ConformanceFailure(
                    f"live server exited {process.returncode}: {output}"
                )
            time.sleep(0.05)
        else:
            raise ConformanceFailure("live server did not create its socket")
        payload = {
            "contract_version": 2,
            "id": "live-isolated-resource-lifecycle",
            "op": "live-flow",
            "socket_path": str(socket_path),
            "constants": constants,
            "workspace_name": f"conformance-{os.getpid()}",
        }
        response = adapter.request(payload, timeout=30)
        expected = {
            "ok": True,
            "value": {
                "pinged": True,
                "created": True,
                "renamed": True,
                "listed": True,
                "closed": True,
                "disappeared": True,
            },
        }
        assert_response(response, expected)
    finally:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
        shutil.rmtree(directory, ignore_errors=True)


def parse_languages(value: str) -> tuple[str, ...]:
    if not value:
        return ()
    names = tuple(item.strip() for item in value.split(",") if item.strip())
    unknown = sorted(set(names) - set(LANGUAGES))
    if unknown:
        raise argparse.ArgumentTypeError(
            f"unknown language(s): {', '.join(unknown)}"
        )
    return names


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run public cmux.protocol/1 SDK conformance"
    )
    parser.add_argument(
        "--languages",
        type=parse_languages,
        default=LANGUAGES,
        help="comma-separated adapters to attempt",
    )
    parser.add_argument(
        "--require",
        type=parse_languages,
        default=(),
        help="comma-separated adapters that may not be skipped",
    )
    parser.add_argument("--no-build", action="store_true")
    parser.add_argument("--fake-only", action="store_true")
    parser.add_argument(
        "--case",
        action="append",
        default=[],
        help="run only the named fake case; repeat for more than one",
    )
    parser.add_argument("--cmux-tui-bin", type=Path)
    args = parser.parse_args(argv)

    fixtures, catalog = load_contract()
    constants = fixtures["constants"]
    operations = catalog["operations"]
    required = set(args.require)
    selected = tuple(args.languages)
    if not required.issubset(selected):
        parser.error("--require must be a subset of --languages")

    BUILD.mkdir(parents=True, exist_ok=True)
    results: list[CaseResult] = []
    specs = adapter_specs()
    for language in selected:
        adapter = Adapter(specs[language])
        try:
            if not args.no_build:
                adapter.build()
            else:
                adapter.check_tools()
        except ToolchainMissing as error:
            if language in required:
                results.append(CaseResult(language, "build", "FAIL", str(error)))
            else:
                results.append(CaseResult(language, "build", "SKIP", str(error)))
            continue
        except ConformanceFailure as error:
            results.append(CaseResult(language, "build", "FAIL", str(error)))
            continue

        cases = fixtures["fake_cases"]
        if args.case:
            cases = [case for case in cases if case["name"] in set(args.case)]
            missing_cases = set(args.case) - {case["name"] for case in cases}
            if missing_cases:
                parser.error(f"unknown case(s): {', '.join(sorted(missing_cases))}")
        for case in cases:
            try:
                run_fake_case(adapter, case, constants, operations)
            except BaseException as error:
                results.append(
                    CaseResult(language, str(case["name"]), "FAIL", str(error))
                )
            else:
                results.append(CaseResult(language, str(case["name"]), "PASS"))
        if not args.fake_only and args.cmux_tui_bin is not None:
            try:
                run_live_case(adapter, args.cmux_tui_bin, constants)
            except BaseException as error:
                results.append(
                    CaseResult(language, "live-isolated-resource-lifecycle", "FAIL", str(error))
                )
            else:
                results.append(
                    CaseResult(language, "live-isolated-resource-lifecycle", "PASS")
                )

    for result in results:
        suffix = f": {result.detail}" if result.detail else ""
        print(f"{result.status:4} {result.language:10} {result.name}{suffix}")
    failures = [result for result in results if result.status == "FAIL"]
    passes = sum(result.status == "PASS" for result in results)
    skips = sum(result.status == "SKIP" for result in results)
    print(
        f"\npublic resource conformance: {passes} passed, "
        f"{len(failures)} failed, {skips} skipped"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
