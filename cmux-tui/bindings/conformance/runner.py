#!/usr/bin/env python3
"""Cross-language conformance for the handwritten cmux resource SDKs."""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import secrets
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
CATALOG = MUX_DIR / "spec" / "resource-operations-v2.json"
BUILD = HERE / ".build" / "resource-v2"
LANGUAGES = ("python", "typescript", "rust", "go", "java", "cpp", "zig")
PROTOCOL = "cmux.protocol/2"
TRANSPORTED_OPERATION_COUNT = 124
MAX_REQUEST_BYTES = 4 * 1024 * 1024
MAX_STREAM_MESSAGES = 256
MAX_STREAM_BYTES = 16 * 1024 * 1024
OPAQUE_STREAM = re.compile(r"^stream_[0-9a-f]{32}$")
OPAQUE_WORKSPACE = re.compile(r"^ws_[0-9a-f]{32}$")
OPAQUE_SCREEN = re.compile(r"^screen_[0-9a-f]{32}$")
OPAQUE_PANE = re.compile(r"^pane_[0-9a-f]{32}$")
OPAQUE_TAB = re.compile(r"^tab_[0-9a-f]{32}$")
OPAQUE_TERMINAL = re.compile(r"^term_[0-9a-f]{32}$")
UNSIGNED_DECIMAL = re.compile(r"^(0|[1-9][0-9]*)$")
LIVE_SETUP_FIELDS = frozenset(
    {
        "pinged",
        "stable_id",
        "stable_renamed",
        "duplicate_ids",
        "ambiguity_code",
        "ambiguity_preserved_all_candidates",
        "no_mutation",
    }
)
LIVE_RESTART_FIELDS = frozenset(
    {
        "same_ids",
        "stable_name_preserved",
        "duplicates_preserved",
        "closed",
        "disappeared",
    }
)
LIVE_CREATION_EXIT_FIELDS = frozenset(
    {
        "correlation_key",
        "created_path",
        "pending_terminal_id",
        "pending_state",
        "pending_lifecycle",
        "creation_state",
        "creation_recovery",
        "creation_generation",
        "creation_revision",
        "exit_state",
        "exit_terminal_id",
        "exit_lifecycle",
        "exit_kind",
        "exit_code",
        "exited_at",
        "exit_revision",
    }
)
LIVE_EXIT_RESTART_FIELDS = frozenset(
    {
        "correlation_key",
        "created_path",
        "creation_state",
        "creation_recovery",
        "creation_generation",
        "creation_revision",
        "exit_state",
        "exit_terminal_id",
        "exit_lifecycle",
        "exit_kind",
        "exit_code",
        "exited_at",
        "exit_revision",
    }
)


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


@dataclasses.dataclass(frozen=True)
class LiveCreationEvidence:
    created_path: dict[str, str]
    correlation_key: str
    creation_generation: str
    creation_revision: str
    exited_at: str
    exit_revision: str


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
        ok = response.get("ok")
        if not isinstance(ok, bool):
            raise ConformanceFailure(
                f"adapter response ok must be a boolean, got {ok!r}"
            )
        expected_fields = (
            {"contract_version", "id", "ok", "value"}
            if ok
            else {"contract_version", "id", "ok", "error"}
        )
        if set(response) != expected_fields:
            raise ConformanceFailure(
                f"adapter response fields must be exactly "
                f"{sorted(expected_fields)}, got {sorted(response)}"
            )
        if not ok:
            error = response["error"]
            if not isinstance(error, dict) or set(error) != {"kind", "message"}:
                raise ConformanceFailure(
                    "adapter error must contain exactly kind and message"
                )
            if error["kind"] not in {
                "adapter",
                "transport",
                "protocol",
                "resource",
            }:
                raise ConformanceFailure(
                    f"adapter error kind is invalid: {error['kind']!r}"
                )
            if not isinstance(error["message"], str) or not error["message"]:
                raise ConformanceFailure(
                    "adapter error message must be a nonempty string"
                )
        return response


@dataclasses.dataclass
class _Connection:
    socket: socket.socket
    writer_lock: threading.Lock = dataclasses.field(default_factory=threading.Lock)


class ResourceV2Server:
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

    def __enter__(self) -> "ResourceV2Server":
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
        if operation == "session.creation.resolve":
            self._expect_creation_resolution(request)
            self._dispatch_creation_resolution(connection, request)
            return
        if operation == "workspace.create":
            self._expect_creation_conflict(request)
            self._dispatch_creation_conflict(connection, request)
            return
        if operation == "terminal.wait_exit":
            self._expect_terminal_wait_exit(request)
            self._dispatch_terminal_wait_exit(connection, request)
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

    def _expect_creation_resolution(self, request: Mapping[str, Any]) -> None:
        self._expect_params(
            request,
            {
                "machine": "current",
                "session": self.constants["session"],
                "correlation_key": self.constants["correlation_key"],
            },
        )

    def _expect_creation_conflict(self, request: Mapping[str, Any]) -> None:
        self._expect_params(
            request,
            {
                "machine": "current",
                "session": self.constants["session"],
                "name": self.constants["name"],
                "initial_content": "empty",
                "correlation_key": self.constants["correlation_key"],
            },
        )
        if request["idempotency_key"] != self.constants["idempotency_key"]:
            raise ConformanceFailure(
                "adapter changed the explicit creation idempotency key"
            )

    def _expect_terminal_wait_exit(self, request: Mapping[str, Any]) -> None:
        expected_timeout = (
            "0" if self.behavior == "terminal-exit-pending" else "5000"
        )
        self._expect_params(
            request,
            {
                "machine": "current",
                "session": self.constants["session"],
                "terminal": self.constants["terminal"],
                "timeout_ms": expected_timeout,
            },
        )

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

    def _dispatch_creation_resolution(
        self, connection: _Connection, request: Mapping[str, Any]
    ) -> None:
        common = {
            "correlation_key": self.constants["correlation_key"],
            "idempotency_key": self.constants["idempotency_key"],
        }
        created_common = {
            **common,
            "state": "created",
            "recovery": "none",
            "generation": self.constants["generation"],
            "revision": self.constants["revision"],
        }
        created_paths = {
            "creation-created-workspace": {
                **created_common,
                "operation": "workspace.create",
                "created_path": {
                    "kind": "workspace",
                    "workspace_id": self.constants["workspace"],
                },
            },
            "creation-created-terminal": {
                **created_common,
                "operation": "workspace.run",
                "created_path": self._created_terminal_path(),
            },
            "creation-created-browser": {
                **created_common,
                "operation": "tab.create_browser",
                "created_path": {
                    "kind": "browser",
                    "workspace_id": self.constants["workspace"],
                    "screen_id": self.constants["screen"],
                    "pane_id": self.constants["pane"],
                    "tab_id": self.constants["tab"],
                    "browser_id": self.constants["browser"],
                },
            },
        }
        result = created_paths.get(self.behavior)
        if result is None:
            other_states = {
                "creation-pending": {
                    **common,
                    "state": "pending",
                    "recovery": "wait",
                    "operation": "pane.run",
                },
                "creation-not-applied-same-key": {
                    **common,
                    "state": "not_applied",
                    "recovery": "retry_same_idempotency_key",
                    "operation": "pane.split",
                },
                "creation-not-applied-new-key": {
                    "correlation_key": self.constants["correlation_key"],
                    "state": "not_applied",
                    "recovery": "retry_new_idempotency_key",
                },
                "creation-indeterminate": {
                    **common,
                    "state": "indeterminate",
                    "recovery": "do_not_retry",
                    "operation": "screen.create",
                },
            }
            result = other_states.get(self.behavior)
        if result is None:
            raise ConformanceFailure(
                f"behavior {self.behavior} cannot resolve a creation"
            )
        self._ok(connection, request, result)

    def _dispatch_creation_conflict(
        self, connection: _Connection, request: Mapping[str, Any]
    ) -> None:
        if self.behavior != "creation-conflict":
            raise ConformanceFailure(
                f"behavior {self.behavior} cannot handle workspace.create"
            )
        self._error(
            connection,
            request,
            {
                "code": "creation.conflict",
                "message": (
                    "correlation key is already bound to different "
                    "creation semantics"
                ),
                "details": {
                    "correlation_key": self.constants["correlation_key"],
                    "existing_operation": "workspace.run",
                    "requested_operation": "workspace.create",
                    "existing_fingerprint": "a" * 64,
                    "requested_fingerprint": "b" * 64,
                },
                "retryable": False,
            },
        )

    def _dispatch_terminal_wait_exit(
        self, connection: _Connection, request: Mapping[str, Any]
    ) -> None:
        if self.behavior == "terminal-exit-pending":
            self._ok(
                connection,
                request,
                {
                    "state": "pending",
                    "terminal_id": self.constants["terminal"],
                    "lifecycle": "running",
                    "revision": self.constants["revision"],
                },
            )
            return
        if self.behavior == "terminal-exit-code":
            self._ok(
                connection,
                request,
                {
                    "state": "exited",
                    "terminal_id": self.constants["terminal"],
                    "lifecycle": "exited",
                    "outcome": {"kind": "exit", "code": 17},
                    "exited_at": self.constants["exited_at"],
                    "revision": self.constants["exit_revision"],
                },
            )
            return
        raise ConformanceFailure(
            f"behavior {self.behavior} cannot handle terminal.wait_exit"
        )

    def _created_terminal_path(self) -> dict[str, Any]:
        return {
            "kind": "terminal",
            "workspace_id": self.constants["workspace"],
            "screen_id": self.constants["screen"],
            "pane_id": self.constants["pane"],
            "tab_id": self.constants["tab"],
            "terminal_id": self.constants["terminal"],
        }

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
            "creation-created-workspace": {"session.creation.resolve": 1},
            "creation-created-terminal": {"session.creation.resolve": 1},
            "creation-created-browser": {"session.creation.resolve": 1},
            "creation-pending": {"session.creation.resolve": 1},
            "creation-not-applied-same-key": {"session.creation.resolve": 1},
            "creation-not-applied-new-key": {"session.creation.resolve": 1},
            "creation-indeterminate": {"session.creation.resolve": 1},
            "creation-conflict": {"workspace.create": 1},
            "terminal-exit-pending": {"terminal.wait_exit": 1},
            "terminal-exit-code": {"terminal.wait_exit": 1},
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
    if (
        not isinstance(operations, dict)
        or len(operations) != TRANSPORTED_OPERATION_COUNT
    ):
        raise ConformanceFailure(
            f"expected {TRANSPORTED_OPERATION_COUNT} transported operations, got "
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
    with ResourceV2Server(
        str(server_spec["behavior"]), constants, operations
    ) as server:
        payload["socket_path"] = str(server.socket_path)
        response = adapter.request(
            payload,
            timeout=75.0 if "overflow" in case["name"] else 20.0,
        )
        server.assert_complete()
        assert_response(response, case["expect"])


def live_transports(language: str) -> tuple[str, ...]:
    if language == "typescript":
        return ("unix", "websocket")
    return ("unix",)


def reserve_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def live_server_command(
    binary: Path,
    socket_path: Path,
    state_path: Path,
    session_name: str,
    websocket_port: int,
    websocket_token: str,
) -> tuple[str, ...]:
    return (
        str(binary),
        "--headless",
        "--session",
        session_name,
        "--socket",
        str(socket_path),
        "--state",
        str(state_path),
        "--ws",
        f"127.0.0.1:{websocket_port}",
        "--ws-token",
        websocket_token,
    )


def unix_socket_ready(path: Path) -> bool:
    if not path.exists():
        return False
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(0.2)
    try:
        connection.connect(str(path))
    except OSError:
        return False
    finally:
        connection.close()
    return True


def tcp_socket_ready(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
            return True
    except OSError:
        return False


def start_live_server(
    binary: Path,
    socket_path: Path,
    state_path: Path,
    session_name: str,
    websocket_token: str,
) -> tuple[subprocess.Popen[str], str]:
    websocket_port = reserve_loopback_port()
    command = live_server_command(
        binary,
        socket_path,
        state_path,
        session_name,
        websocket_port,
        websocket_token,
    )
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout else ""
            raise ConformanceFailure(
                f"live server exited {process.returncode}: {output}"
            )
        if unix_socket_ready(socket_path) and tcp_socket_ready(websocket_port):
            return process, f"ws://127.0.0.1:{websocket_port}"
        time.sleep(0.05)
    stop_live_server(process, socket_path)
    raise ConformanceFailure(
        "live server did not make both Unix and WebSocket listeners ready"
    )


def stop_live_server(
    process: subprocess.Popen[str],
    socket_path: Path,
) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    deadline = time.monotonic() + 1
    while socket_path.exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    if socket_path.exists():
        socket_path.unlink()


def response_value(
    response: Mapping[str, Any],
    fields: frozenset[str],
    phase: str,
) -> dict[str, Any]:
    if response.get("ok") is not True:
        raise ConformanceFailure(
            f"{phase} adapter request failed: "
            f"{json.dumps(response.get('error'), ensure_ascii=False)}"
        )
    value = response.get("value")
    if not isinstance(value, dict):
        raise ConformanceFailure(f"{phase} result must be an object")
    if set(value) != fields:
        raise ConformanceFailure(
            f"{phase} result fields must be exactly {sorted(fields)}, "
            f"got {sorted(value)}"
        )
    return value


def require_unsigned_decimal(value: Any, field: str, phase: str) -> str:
    if not isinstance(value, str) or UNSIGNED_DECIMAL.fullmatch(value) is None:
        raise ConformanceFailure(
            f"{phase} {field} must be an unsigned decimal string, got {value!r}"
        )
    return value


def require_created_terminal_path(
    value: Any,
    phase: str,
) -> dict[str, str]:
    fields = {
        "kind",
        "workspace_id",
        "screen_id",
        "pane_id",
        "tab_id",
        "terminal_id",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise ConformanceFailure(
            f"{phase} created_path must be an exact terminal path"
        )
    checks = {
        "workspace_id": OPAQUE_WORKSPACE,
        "screen_id": OPAQUE_SCREEN,
        "pane_id": OPAQUE_PANE,
        "tab_id": OPAQUE_TAB,
        "terminal_id": OPAQUE_TERMINAL,
    }
    if value["kind"] != "terminal":
        raise ConformanceFailure(
            f"{phase} created_path kind must be terminal, got "
            f"{value['kind']!r}"
        )
    for field, pattern in checks.items():
        identifier = value[field]
        if (
            not isinstance(identifier, str)
            or pattern.fullmatch(identifier) is None
        ):
            raise ConformanceFailure(
                f"{phase} created_path {field} is invalid: {identifier!r}"
            )
    return {field: str(value[field]) for field in fields}


def validate_live_setup(
    response: Mapping[str, Any],
    transport: str,
) -> tuple[str, list[str]]:
    value = response_value(response, LIVE_SETUP_FIELDS, f"{transport} setup")
    stable_id = value["stable_id"]
    duplicate_ids = value["duplicate_ids"]
    if not isinstance(stable_id, str) or OPAQUE_WORKSPACE.fullmatch(stable_id) is None:
        raise ConformanceFailure(
            f"{transport} setup returned invalid stable workspace id {stable_id!r}"
        )
    if (
        not isinstance(duplicate_ids, list)
        or len(duplicate_ids) != 2
        or any(
            not isinstance(identifier, str)
            or OPAQUE_WORKSPACE.fullmatch(identifier) is None
            for identifier in duplicate_ids
        )
    ):
        raise ConformanceFailure(
            f"{transport} setup returned invalid duplicate ids {duplicate_ids!r}"
        )
    if len({stable_id, *duplicate_ids}) != 3:
        raise ConformanceFailure(
            f"{transport} setup did not create three distinct workspace ids"
        )
    expected_true = (
        "pinged",
        "stable_renamed",
        "ambiguity_preserved_all_candidates",
        "no_mutation",
    )
    failed = [field for field in expected_true if value[field] is not True]
    if failed:
        raise ConformanceFailure(
            f"{transport} setup failed assertions: {', '.join(failed)}"
        )
    if value["ambiguity_code"] != "selector.ambiguous":
        raise ConformanceFailure(
            f"{transport} setup expected selector.ambiguous, "
            f"got {value['ambiguity_code']!r}"
        )
    return stable_id, duplicate_ids


def validate_live_restart(
    response: Mapping[str, Any],
    transport: str,
) -> None:
    value = response_value(response, LIVE_RESTART_FIELDS, f"{transport} restart")
    failed = [field for field in LIVE_RESTART_FIELDS if value[field] is not True]
    if failed:
        raise ConformanceFailure(
            f"{transport} restart failed assertions: {', '.join(sorted(failed))}"
        )


def validate_live_creation_exit(
    response: Mapping[str, Any],
    transport: str,
    expected_correlation_key: str,
) -> LiveCreationEvidence:
    phase = f"{transport} creation-exit"
    value = response_value(response, LIVE_CREATION_EXIT_FIELDS, phase)
    if value["correlation_key"] != expected_correlation_key:
        raise ConformanceFailure(
            f"{phase} correlation_key {value['correlation_key']!r} != "
            f"{expected_correlation_key!r}"
        )
    created_path = require_created_terminal_path(
        value["created_path"], phase
    )
    terminal_id = created_path["terminal_id"]
    exact = {
        "pending_state": "pending",
        "creation_state": "created",
        "creation_recovery": "none",
        "exit_state": "exited",
        "exit_lifecycle": "exited",
        "exit_kind": "exit",
    }
    mismatches = [
        f"{field}={value[field]!r}"
        for field, expected in exact.items()
        if value[field] != expected
    ]
    if value["pending_lifecycle"] not in {"launching", "running"}:
        mismatches.append(
            f"pending_lifecycle={value['pending_lifecycle']!r}"
        )
    for field in ("pending_terminal_id", "exit_terminal_id"):
        if value[field] != terminal_id:
            mismatches.append(f"{field}={value[field]!r}")
    if (
        isinstance(value["exit_code"], bool)
        or not isinstance(value["exit_code"], int)
        or value["exit_code"] != 17
    ):
        mismatches.append(f"exit_code={value['exit_code']!r}")
    generation = value["creation_generation"]
    if not isinstance(generation, str) or not 1 <= len(generation) <= 128:
        mismatches.append(f"creation_generation={generation!r}")
    if mismatches:
        raise ConformanceFailure(
            f"{phase} failed assertions: {', '.join(mismatches)}"
        )
    return LiveCreationEvidence(
        created_path=created_path,
        correlation_key=expected_correlation_key,
        creation_generation=generation,
        creation_revision=require_unsigned_decimal(
            value["creation_revision"], "creation_revision", phase
        ),
        exited_at=require_unsigned_decimal(
            value["exited_at"], "exited_at", phase
        ),
        exit_revision=require_unsigned_decimal(
            value["exit_revision"], "exit_revision", phase
        ),
    )


def validate_live_exit_restart(
    response: Mapping[str, Any],
    transport: str,
    expected: LiveCreationEvidence,
) -> None:
    phase = f"{transport} exit-restart"
    value = response_value(response, LIVE_EXIT_RESTART_FIELDS, phase)
    exact = {
        "correlation_key": expected.correlation_key,
        "created_path": expected.created_path,
        "creation_state": "created",
        "creation_recovery": "none",
        "creation_generation": expected.creation_generation,
        "creation_revision": expected.creation_revision,
        "exit_state": "exited",
        "exit_terminal_id": expected.created_path["terminal_id"],
        "exit_lifecycle": "exited",
        "exit_kind": "exit",
        "exit_code": 17,
        "exited_at": expected.exited_at,
        "exit_revision": expected.exit_revision,
    }
    mismatches = [
        f"{field}={value[field]!r}"
        for field, wanted in exact.items()
        if (
            value[field] != wanted
            or (
                field == "exit_code"
                and isinstance(value[field], bool)
            )
        )
    ]
    if mismatches:
        raise ConformanceFailure(
            f"{phase} failed assertions: {', '.join(mismatches)}"
        )
    require_unsigned_decimal(value["exited_at"], "exited_at", phase)
    require_unsigned_decimal(value["exit_revision"], "exit_revision", phase)
    require_unsigned_decimal(
        value["creation_revision"], "creation_revision", phase
    )


def live_payload(
    *,
    identifier: str,
    operation: str,
    transport: str,
    socket_path: Path,
    websocket_url: str,
    websocket_token: str,
    constants: Mapping[str, str],
    workspace_name: str,
    key_prefix: str,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "contract_version": 2,
        "id": identifier,
        "op": operation,
        "transport": transport,
        "socket_path": str(socket_path),
        "constants": constants,
        "workspace_name": workspace_name,
        "key_prefix": key_prefix,
    }
    if transport == "websocket":
        payload["websocket_url"] = websocket_url
        payload["websocket_token"] = websocket_token
    return payload


def run_live_case(
    adapter: Adapter,
    binary: Path,
    constants: Mapping[str, str],
) -> tuple[str, ...]:
    try:
        exact_binary = binary.expanduser().resolve(strict=True)
    except FileNotFoundError as error:
        raise ConformanceFailure(
            f"cmux-tui binary does not exist: {binary}"
        ) from error
    if not exact_binary.is_file() or not os.access(exact_binary, os.X_OK):
        raise ConformanceFailure(
            f"cmux-tui binary is not an executable file: {exact_binary}"
        )

    directory = Path(
        tempfile.mkdtemp(prefix=f"cmux-resource-{adapter.spec.language}-")
    )
    socket_path = directory / "session.sock"
    state_path = directory / "state"
    nonce = secrets.token_hex(4)
    session_name = f"resource-v2-{adapter.spec.language}-{nonce}"
    websocket_token = f"conformance-{secrets.token_hex(16)}"
    base_name = f"conformance-{adapter.spec.language}-{nonce}"
    transports = live_transports(adapter.spec.language)
    process: subprocess.Popen[str] | None = None
    setup: dict[str, tuple[str, list[str]]] = {}
    creation: dict[str, LiveCreationEvidence] = {}
    try:
        process, websocket_url = start_live_server(
            exact_binary,
            socket_path,
            state_path,
            session_name,
            websocket_token,
        )
        for transport in transports:
            workspace_name = f"{base_name}-{transport}"
            payload = live_payload(
                identifier=f"live-{transport}-setup",
                operation="live-setup",
                transport=transport,
                socket_path=socket_path,
                websocket_url=websocket_url,
                websocket_token=websocket_token,
                constants=constants,
                workspace_name=workspace_name,
                key_prefix=transport,
            )
            setup[transport] = validate_live_setup(
                adapter.request(payload, timeout=45),
                transport,
            )
            stable_id, _ = setup[transport]
            correlation_key = f"{transport}-terminal-correlation"
            payload = live_payload(
                identifier=f"live-{transport}-creation-exit",
                operation="live-creation-exit",
                transport=transport,
                socket_path=socket_path,
                websocket_url=websocket_url,
                websocket_token=websocket_token,
                constants=constants,
                workspace_name=workspace_name,
                key_prefix=transport,
            )
            payload.update(
                {
                    "expected_stable_id": stable_id,
                    "exit_shell": "sleep 2; exit 17",
                    "pending_timeout_ms": "0",
                    "exit_timeout_ms": "10000",
                    "expected_exit_code": 17,
                }
            )
            creation[transport] = validate_live_creation_exit(
                adapter.request(payload, timeout=45),
                transport,
                correlation_key,
            )

        stop_live_server(process, socket_path)
        process = None
        process, websocket_url = start_live_server(
            exact_binary,
            socket_path,
            state_path,
            session_name,
            websocket_token,
        )
        for transport in transports:
            stable_id, duplicate_ids = setup[transport]
            evidence = creation[transport]
            workspace_name = f"{base_name}-{transport}"
            payload = live_payload(
                identifier=f"live-{transport}-exit-restart",
                operation="live-exit-restart",
                transport=transport,
                socket_path=socket_path,
                websocket_url=websocket_url,
                websocket_token=websocket_token,
                constants=constants,
                workspace_name=workspace_name,
                key_prefix=transport,
            )
            payload.update(
                {
                    "expected_created_path": evidence.created_path,
                    "expected_correlation_key": evidence.correlation_key,
                    "expected_creation_generation": (
                        evidence.creation_generation
                    ),
                    "expected_creation_revision": evidence.creation_revision,
                    "expected_exited_at": evidence.exited_at,
                    "expected_exit_revision": evidence.exit_revision,
                    "exit_timeout_ms": "0",
                    "expected_exit_code": 17,
                }
            )
            validate_live_exit_restart(
                adapter.request(payload, timeout=45),
                transport,
                evidence,
            )
            payload = live_payload(
                identifier=f"live-{transport}-restart",
                operation="live-restart",
                transport=transport,
                socket_path=socket_path,
                websocket_url=websocket_url,
                websocket_token=websocket_token,
                constants=constants,
                workspace_name=workspace_name,
                key_prefix=transport,
            )
            payload["expected_stable_id"] = stable_id
            payload["expected_duplicate_ids"] = duplicate_ids
            validate_live_restart(
                adapter.request(payload, timeout=45),
                transport,
            )
        return transports
    finally:
        if process is not None:
            stop_live_server(process, socket_path)
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
        description="Run public cmux.protocol/2 SDK conformance"
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
            transports = live_transports(language)
            try:
                run_live_case(adapter, args.cmux_tui_bin, constants)
            except BaseException as error:
                for transport in transports:
                    results.append(
                        CaseResult(
                            language,
                            f"live-creation-exit-restart-{transport}",
                            "FAIL",
                            str(error),
                        )
                    )
            else:
                for transport in transports:
                    results.append(
                        CaseResult(
                            language,
                            f"live-creation-exit-restart-{transport}",
                            "PASS",
                        )
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
