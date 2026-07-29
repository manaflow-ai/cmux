from __future__ import annotations

import json
import socket
import unittest
from pathlib import Path

from runner import (
    FIXTURES,
    LANGUAGES,
    MAX_STREAM_BYTES,
    MAX_STREAM_MESSAGES,
    PROTOCOL,
    ConformanceFailure,
    ResourceV1Server,
    assert_response,
    live_server_command,
    live_transports,
    load_contract,
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


class ContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixtures, cls.catalog = load_contract()

    def test_all_handwritten_language_roots_are_required(self) -> None:
        self.assertEqual(
            LANGUAGES,
            ("python", "typescript", "rust", "go", "java", "cpp", "zig"),
        )

    def test_catalog_is_public_v1_and_has_122_transported_operations(self) -> None:
        self.assertEqual(self.catalog["protocol"], PROTOCOL)
        self.assertEqual(len(self.catalog["operations"]), 122)
        self.assertEqual(
            self.catalog["operations"]["workspace.rename"]["class"], "mutation"
        )
        self.assertEqual(
            self.catalog["operations"]["session.events"]["class"], "stream_open"
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
            "resource-v1-test",
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
                "resource-v1-test",
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


class EnvelopeServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixtures, cls.catalog = load_contract()
        cls.constants = cls.fixtures["constants"]
        cls.operations = cls.catalog["operations"]

    def connect(self, server: ResourceV1Server) -> socket.socket:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.connect(str(server.socket_path))
        return connection

    def test_read_accepts_only_exact_public_envelope(self) -> None:
        with ResourceV1Server(
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
            with ResourceV1Server(
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
        with ResourceV1Server(
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

    def test_cancel_end_is_written_before_cancel_response(self) -> None:
        with ResourceV1Server(
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


if __name__ == "__main__":
    unittest.main()
