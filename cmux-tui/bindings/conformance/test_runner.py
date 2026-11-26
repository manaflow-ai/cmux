from __future__ import annotations

import json
import socket
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from runner import (
    Adapter,
    AdapterSpec,
    FIXTURES,
    LANGUAGES,
    MAX_STREAM_BYTES,
    MAX_STREAM_MESSAGES,
    PROTOCOL,
    TRANSPORTED_OPERATION_COUNT,
    ConformanceFailure,
    ResourceV2Server,
    assert_response,
    live_server_command,
    live_transports,
    load_contract,
    run_live_case,
    validate_live_creation_exit,
    validate_live_exit_restart,
    validate_live_restart,
    validate_live_setup,
)


def request(connection: socket.socket, value: dict) -> dict:
    connection.sendall(
        json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()
        + b"\n"
    )
    source = connection.makefile("rb")
    return json.loads(source.readline())


class FakeLiveAdapter:
    def __init__(self, language: str = "typescript") -> None:
        self.spec = SimpleNamespace(language=language)
        self.requests: list[dict] = []

    def request(self, payload: dict, *, timeout: float = 45.0) -> dict:
        self.requests.append(json.loads(json.dumps(payload)))
        transport = payload["transport"]
        digit = "1" if transport == "unix" else "4"
        terminal_digit = "7" if transport == "unix" else "8"
        values = {
            "live-setup": {
                "pinged": True,
                "stable_id": f"ws_{digit * 32}",
                "stable_renamed": True,
                "duplicate_ids": [
                    f"ws_{str(int(digit) + 1) * 32}",
                    f"ws_{str(int(digit) + 2) * 32}",
                ],
                "ambiguity_code": "selector.ambiguous",
                "ambiguity_preserved_all_candidates": True,
                "no_mutation": True,
            },
            "live-restart": {
                "same_ids": True,
                "stable_name_preserved": True,
                "duplicates_preserved": True,
                "closed": True,
                "disappeared": True,
            },
        }
        if payload["op"] == "live-creation-exit":
            value = {
                "correlation_key": f"{transport}-terminal-correlation",
                "created_path": {
                    "kind": "terminal",
                    "workspace_id": payload["expected_stable_id"],
                    "screen_id": f"screen_{terminal_digit * 32}",
                    "pane_id": f"pane_{terminal_digit * 32}",
                    "tab_id": f"tab_{terminal_digit * 32}",
                    "terminal_id": f"term_{terminal_digit * 32}",
                },
                "pending_terminal_id": f"term_{terminal_digit * 32}",
                "pending_state": "pending",
                "pending_lifecycle": "running",
                "creation_state": "created",
                "creation_recovery": "none",
                "creation_generation": f"generation-{transport}",
                "creation_revision": "101",
                "exit_state": "exited",
                "exit_terminal_id": f"term_{terminal_digit * 32}",
                "exit_lifecycle": "exited",
                "exit_kind": "exit",
                "exit_code": 17,
                "exited_at": "1001",
                "exit_revision": "102",
            }
        elif payload["op"] == "live-exit-restart":
            path = payload["expected_created_path"]
            value = {
                "correlation_key": payload["expected_correlation_key"],
                "created_path": path,
                "creation_state": "created",
                "creation_recovery": "none",
                "creation_generation": payload[
                    "expected_creation_generation"
                ],
                "creation_revision": payload["expected_creation_revision"],
                "exit_state": "exited",
                "exit_terminal_id": path["terminal_id"],
                "exit_lifecycle": "exited",
                "exit_kind": "exit",
                "exit_code": 17,
                "exited_at": payload["expected_exited_at"],
                "exit_revision": payload["expected_exit_revision"],
            }
        else:
            value = values[payload["op"]]
        return {
            "contract_version": 2,
            "id": payload["id"],
            "ok": True,
            "value": value,
        }


class ContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixtures, cls.catalog = load_contract()

    def test_all_handwritten_language_roots_are_required(self) -> None:
        self.assertEqual(
            LANGUAGES,
            ("python", "typescript", "rust", "go", "java", "cpp", "zig"),
        )

    def test_catalog_is_public_v2_and_has_expected_transported_operations(
        self,
    ) -> None:
        self.assertEqual(self.catalog["protocol"], PROTOCOL)
        self.assertEqual(
            len(self.catalog["operations"]),
            TRANSPORTED_OPERATION_COUNT,
        )
        self.assertEqual(
            self.catalog["operations"]["request.cancel"]["class"],
            "connection_control",
        )
        self.assertEqual(
            self.catalog["operations"]["workspace.rename"]["class"], "mutation"
        )
        self.assertEqual(
            self.catalog["operations"]["session.events"]["class"], "stream_open"
        )
        self.assertEqual(
            self.catalog["operations"]["session.creation.resolve"]["class"],
            "read",
        )
        self.assertEqual(
            self.catalog["operations"]["terminal.wait_exit"]["class"], "read"
        )

    def test_fixtures_cover_every_requested_semantic(self) -> None:
        names = {case["name"] for case in self.fixtures["fake_cases"]}
        required = {
            "read-envelope-and-decimal",
            "mutation-idempotent-replay",
            "mutation-indeterminate-is-one-request",
            "revision-conflict-is-structured",
            "duplicate-name-ambiguity-preserves-all-candidates",
            "typed-stream-preserves-unknown-and-decimals",
            "cancel-purges-queued-items-and-orders-end-before-response",
            "message-overflow-is-stream-local",
            "byte-overflow-is-stream-local",
            "sensitive-values-redact",
            "creation-resolve-created-workspace-path",
            "creation-resolve-created-terminal-path",
            "creation-resolve-created-browser-path",
            "creation-resolve-pending-means-wait",
            "creation-resolve-prepared-retries-same-key",
            "creation-resolve-absent-retries-new-key",
            "creation-resolve-indeterminate-forbids-retry",
            "creation-correlation-conflict-is-structured",
            "terminal-wait-exit-timeout-is-pending",
            "terminal-wait-exit-preserves-code-17",
        }
        self.assertEqual(names, required)

    def test_overflow_limits_are_the_normative_independent_bounds(self) -> None:
        self.assertEqual(MAX_STREAM_MESSAGES, 256)
        self.assertEqual(MAX_STREAM_BYTES, 16 * 1024 * 1024)

    def test_live_matrix_adds_websocket_only_where_supported(self) -> None:
        self.assertEqual(live_transports("typescript"), ("unix", "websocket"))
        for language in set(LANGUAGES) - {"typescript"}:
            self.assertEqual(live_transports(language), ("unix",))

    def test_live_server_command_is_durable_and_uses_exact_binary(self) -> None:
        command = live_server_command(
            Path("/tmp/exact/cmux-tui"),
            Path("/tmp/socket"),
            Path("/tmp/state"),
            "resource-v2-test",
            43210,
            "secret",
        )
        self.assertEqual(command[0], "/tmp/exact/cmux-tui")
        self.assertNotIn("--ephemeral", command)
        self.assertEqual(
            command,
            (
                "/tmp/exact/cmux-tui",
                "--headless",
                "--session",
                "resource-v2-test",
                "--socket",
                "/tmp/socket",
                "--state",
                "/tmp/state",
                "--ws",
                "127.0.0.1:43210",
                "--ws-token",
                "secret",
            ),
        )

    def test_live_results_require_distinct_opaque_ids_and_exact_fields(self) -> None:
        setup = {
            "contract_version": 2,
            "id": "live-unix-setup",
            "ok": True,
            "value": {
                "pinged": True,
                "stable_id": "ws_11111111111111111111111111111111",
                "stable_renamed": True,
                "duplicate_ids": [
                    "ws_22222222222222222222222222222222",
                    "ws_33333333333333333333333333333333",
                ],
                "ambiguity_code": "selector.ambiguous",
                "ambiguity_preserved_all_candidates": True,
                "no_mutation": True,
            },
        }
        self.assertEqual(
            validate_live_setup(setup, "unix"),
            (
                "ws_11111111111111111111111111111111",
                [
                    "ws_22222222222222222222222222222222",
                    "ws_33333333333333333333333333333333",
                ],
            ),
        )
        duplicate = json.loads(json.dumps(setup))
        duplicate["value"]["duplicate_ids"][1] = duplicate["value"]["stable_id"]
        with self.assertRaisesRegex(ConformanceFailure, "three distinct"):
            validate_live_setup(duplicate, "unix")
        extra = json.loads(json.dumps(setup))
        extra["value"]["unexpected"] = True
        with self.assertRaisesRegex(ConformanceFailure, "fields must be exactly"):
            validate_live_setup(extra, "unix")

    def test_live_restart_requires_every_persistence_and_cleanup_assertion(self) -> None:
        restart = {
            "contract_version": 2,
            "id": "live-unix-restart",
            "ok": True,
            "value": {
                "same_ids": True,
                "stable_name_preserved": True,
                "duplicates_preserved": True,
                "closed": True,
                "disappeared": True,
            },
        }
        validate_live_restart(restart, "unix")
        restart["value"]["same_ids"] = False
        with self.assertRaisesRegex(ConformanceFailure, "same_ids"):
            validate_live_restart(restart, "unix")


class LiveOrchestrationTests(unittest.TestCase):
    def run_mock_live(self) -> tuple[FakeLiveAdapter, object, object]:
        adapter = FakeLiveAdapter()
        with (
            patch("runner.start_live_server") as start,
            patch("runner.stop_live_server") as stop,
        ):
            start.side_effect = [
                (object(), "ws://127.0.0.1:41001"),
                (object(), "ws://127.0.0.1:41002"),
            ]
            transports = run_live_case(adapter, Path(sys.executable), {})
            self.assertEqual(transports, ("unix", "websocket"))
            return adapter, start, stop

    def test_live_orchestration_orders_creation_exit_and_cleanup(self) -> None:
        adapter, _, stop = self.run_mock_live()
        self.assertEqual(
            [payload["op"] for payload in adapter.requests],
            [
                "live-setup",
                "live-creation-exit",
                "live-setup",
                "live-creation-exit",
                "live-exit-restart",
                "live-restart",
                "live-exit-restart",
                "live-restart",
            ],
        )
        for payload in (
            item
            for item in adapter.requests
            if item["op"] == "live-creation-exit"
        ):
            self.assertEqual(payload["pending_timeout_ms"], "0")
            self.assertEqual(payload["exit_timeout_ms"], "10000")
            self.assertEqual(payload["expected_exit_code"], 17)
            self.assertEqual(payload["exit_shell"], "sleep 2; exit 17")
        self.assertEqual(stop.call_count, 2)

    def test_restart_reuses_state_session_and_passes_exact_evidence(self) -> None:
        adapter, start, _ = self.run_mock_live()
        self.assertEqual(start.call_count, 2)
        first = start.call_args_list[0].args
        second = start.call_args_list[1].args
        self.assertEqual(first[0], second[0])
        self.assertEqual(first[1], second[1])
        self.assertEqual(first[2], second[2])
        self.assertEqual(first[3], second[3])
        self.assertEqual(first[4], second[4])

        creation = {
            payload["transport"]: payload
            for payload in adapter.requests
            if payload["op"] == "live-creation-exit"
        }
        restarted = {
            payload["transport"]: payload
            for payload in adapter.requests
            if payload["op"] == "live-exit-restart"
        }
        for transport in ("unix", "websocket"):
            self.assertEqual(
                restarted[transport]["expected_correlation_key"],
                f"{transport}-terminal-correlation",
            )
            self.assertEqual(
                restarted[transport]["expected_created_path"]["workspace_id"],
                creation[transport]["expected_stable_id"],
            )
            self.assertEqual(
                restarted[transport]["expected_exit_revision"], "102"
            )
            self.assertEqual(
                restarted[transport]["expected_exited_at"], "1001"
            )


class EnvelopeServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixtures, cls.catalog = load_contract()
        cls.constants = cls.fixtures["constants"]
        cls.operations = cls.catalog["operations"]

    def connect(self, server: ResourceV2Server) -> socket.socket:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(str(server.socket_path))
        return connection

    def test_read_accepts_only_exact_public_envelope(self) -> None:
        with ResourceV2Server(
            "read", self.constants, self.operations
        ) as server:
            with self.connect(server) as connection:
                response = request(
                    connection,
                    {
                        "protocol": PROTOCOL,
                        "type": "request",
                        "id": "test-read",
                        "operation": "session.ping",
                        "params": {
                            "machine": "current",
                            "session": self.constants["session"],
                        },
                    },
                )
                self.assertTrue(response["ok"])
                self.assertEqual(
                    response["result"]["cursor"]["revision"],
                    self.constants["revision"],
                )
            server.assert_complete()

    def test_read_rejects_idempotency_key(self) -> None:
        with self.assertRaisesRegex(
            ConformanceFailure, "envelope keys"
        ):
            with ResourceV2Server(
                "read", self.constants, self.operations
            ) as server:
                with self.connect(server) as connection:
                    connection.sendall(
                        json.dumps(
                            {
                                "protocol": PROTOCOL,
                                "type": "request",
                                "id": "bad-read",
                                "operation": "session.ping",
                                "params": {
                                    "machine": "current",
                                    "session": self.constants["session"],
                                },
                                "idempotency_key": "forbidden",
                            }
                        ).encode()
                        + b"\n"
                    )
                server.wait_for_requests(1, timeout=0.2)

    def test_mutation_requires_exact_key_and_revision(self) -> None:
        with ResourceV2Server(
            "mutation-replay", self.constants, self.operations
        ) as server:
            with self.connect(server) as connection:
                envelope = {
                    "protocol": PROTOCOL,
                    "type": "request",
                    "id": "mutation-1",
                    "operation": "workspace.rename",
                    "params": {
                        "machine": "current",
                        "session": self.constants["session"],
                        "workspace": self.constants["workspace"],
                        "name": self.constants["name"],
                        "expected_revision": self.constants["revision"],
                    },
                    "idempotency_key": self.constants["idempotency_key"],
                }
                first = request(connection, envelope)
                envelope["id"] = "mutation-2"
                second = request(connection, envelope)
                self.assertFalse(first["result"]["replayed"])
                self.assertTrue(second["result"]["replayed"])
            server.assert_complete()

    def test_creation_resolution_is_a_read_and_preserves_terminal_path(self) -> None:
        with ResourceV2Server(
            "creation-created-terminal", self.constants, self.operations
        ) as server:
            with self.connect(server) as connection:
                response = request(
                    connection,
                    {
                        "protocol": PROTOCOL,
                        "type": "request",
                        "id": "resolve-created",
                        "operation": "session.creation.resolve",
                        "params": {
                            "machine": "current",
                            "session": self.constants["session"],
                            "correlation_key": self.constants[
                                "correlation_key"
                            ],
                        },
                    },
                )
            self.assertTrue(response["ok"])
            self.assertEqual(response["result"]["state"], "created")
            self.assertEqual(
                response["result"]["created_path"]["terminal_id"],
                self.constants["terminal"],
            )
            server.assert_complete()

    def test_creation_conflict_preserves_both_semantics(self) -> None:
        with ResourceV2Server(
            "creation-conflict", self.constants, self.operations
        ) as server:
            with self.connect(server) as connection:
                response = request(
                    connection,
                    {
                        "protocol": PROTOCOL,
                        "type": "request",
                        "id": "conflicting-create",
                        "operation": "workspace.create",
                        "params": {
                            "machine": "current",
                            "session": self.constants["session"],
                            "name": self.constants["name"],
                            "initial_content": "empty",
                            "correlation_key": self.constants[
                                "correlation_key"
                            ],
                        },
                        "idempotency_key": self.constants[
                            "idempotency_key"
                        ],
                    },
                )
            self.assertFalse(response["ok"])
            self.assertEqual(response["error"]["code"], "creation.conflict")
            self.assertEqual(
                response["error"]["details"]["existing_operation"],
                "workspace.run",
            )
            self.assertEqual(
                response["error"]["details"]["requested_operation"],
                "workspace.create",
            )
            server.assert_complete()

    def test_wait_exit_timeout_is_a_pending_value(self) -> None:
        with ResourceV2Server(
            "terminal-exit-pending", self.constants, self.operations
        ) as server:
            with self.connect(server) as connection:
                response = request(
                    connection,
                    {
                        "protocol": PROTOCOL,
                        "type": "request",
                        "id": "wait-pending",
                        "operation": "terminal.wait_exit",
                        "params": {
                            "machine": "current",
                            "session": self.constants["session"],
                            "terminal": self.constants["terminal"],
                            "timeout_ms": "0",
                        },
                    },
                )
            self.assertTrue(response["ok"])
            self.assertEqual(response["result"]["state"], "pending")
            self.assertEqual(response["result"]["lifecycle"], "running")
            server.assert_complete()

    def test_cancel_end_is_written_before_cancel_response(self) -> None:
        with ResourceV2Server(
            "stream-cancel", self.constants, self.operations
        ) as server:
            with self.connect(server) as connection:
                stream_id = "stream_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                source = connection.makefile("rwb")
                source.write(
                    json.dumps(
                        {
                            "protocol": PROTOCOL,
                            "type": "request",
                            "id": "open",
                            "operation": "session.events",
                            "params": {
                                "machine": "current",
                                "session": self.constants["session"],
                                "stream_id": stream_id,
                            },
                        },
                        separators=(",", ":"),
                    ).encode()
                    + b"\n"
                )
                source.flush()
                self.assertEqual(json.loads(source.readline())["type"], "response")
                self.assertEqual(json.loads(source.readline())["type"], "stream_item")
                source.write(
                    json.dumps(
                        {
                            "protocol": PROTOCOL,
                            "type": "request",
                            "id": "cancel",
                            "operation": "stream.cancel",
                            "params": {
                                "machine": "current",
                                "session": self.constants["session"],
                                "stream": stream_id,
                            },
                        },
                        separators=(",", ":"),
                    ).encode()
                    + b"\n"
                )
                source.flush()
                self.assertEqual(json.loads(source.readline())["type"], "stream_end")
                self.assertEqual(json.loads(source.readline())["type"], "response")
            server.assert_complete()


class ResultMatchingTests(unittest.TestCase):
    def test_result_comparison_is_exact(self) -> None:
        assert_response(
            {"ok": True, "value": {"revision": "42"}},
            {"ok": True, "value": {"revision": "42"}},
        )
        with self.assertRaises(ConformanceFailure):
            assert_response(
                {"ok": True, "value": {"revision": 42}},
                {"ok": True, "value": {"revision": "42"}},
            )

    def test_live_results_reject_malformed_types_and_extra_fields(self) -> None:
        adapter = FakeLiveAdapter("python")
        payload = {
            "contract_version": 2,
            "id": "live-unix-creation-exit",
            "op": "live-creation-exit",
            "transport": "unix",
            "expected_stable_id": "ws_11111111111111111111111111111111",
        }
        response = adapter.request(payload)
        evidence = validate_live_creation_exit(
            response, "unix", "unix-terminal-correlation"
        )

        numeric_decimal = json.loads(json.dumps(response))
        numeric_decimal["value"]["exited_at"] = 1001
        with self.assertRaisesRegex(
            ConformanceFailure, "unsigned decimal string"
        ):
            validate_live_creation_exit(
                numeric_decimal, "unix", "unix-terminal-correlation"
            )

        extra = json.loads(json.dumps(response))
        extra["value"]["unexpected"] = True
        with self.assertRaisesRegex(
            ConformanceFailure, "fields must be exactly"
        ):
            validate_live_creation_exit(
                extra, "unix", "unix-terminal-correlation"
            )

        restart_payload = {
            "contract_version": 2,
            "id": "live-unix-exit-restart",
            "op": "live-exit-restart",
            "transport": "unix",
            "expected_created_path": evidence.created_path,
            "expected_correlation_key": evidence.correlation_key,
            "expected_creation_generation": evidence.creation_generation,
            "expected_creation_revision": evidence.creation_revision,
            "expected_exited_at": evidence.exited_at,
            "expected_exit_revision": evidence.exit_revision,
        }
        restarted = adapter.request(restart_payload)
        restarted["value"]["exit_revision"] = "103"
        with self.assertRaisesRegex(ConformanceFailure, "exit_revision"):
            validate_live_exit_restart(restarted, "unix", evidence)


class AdapterProcessTests(unittest.TestCase):
    def test_adapter_timeout_kills_the_child(self) -> None:
        adapter = Adapter(
            AdapterSpec(
                "timeout",
                (),
                (),
                (
                    sys.executable,
                    "-c",
                    "import time; time.sleep(5)",
                ),
                Path.cwd(),
            )
        )
        with self.assertRaisesRegex(ConformanceFailure, "timed out"):
            adapter.request({"id": "timeout"}, timeout=0.01)

    def test_adapter_rejects_malformed_success_envelope(self) -> None:
        program = (
            "import json,sys;"
            "p=json.loads(sys.stdin.readline());"
            "print(json.dumps({'contract_version':2,'id':p['id'],"
            "'ok':'true','value':{}}))"
        )
        adapter = Adapter(
            AdapterSpec(
                "malformed",
                (),
                (),
                (sys.executable, "-c", program),
                Path.cwd(),
            )
        )
        with self.assertRaisesRegex(ConformanceFailure, "must be a boolean"):
            adapter.request({"id": "malformed"})


if __name__ == "__main__":
    unittest.main()
