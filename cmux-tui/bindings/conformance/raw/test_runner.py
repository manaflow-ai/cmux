from __future__ import annotations

import json
import socket
import unittest

from runner import (
    FIXTURES,
    LANGUAGES,
    RAW_CATALOGS,
    ConformanceFailure,
    FakeServer,
    assert_case_response,
    partial_match,
)


class FixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixtures = json.loads(FIXTURES.read_text())

    def test_all_seven_language_adapters_are_required_by_the_contract(self) -> None:
        self.assertEqual(
            LANGUAGES,
            ("python", "typescript", "rust", "go", "java", "cpp", "zig"),
        )

    def test_raw_metadata_baselines_are_frozen_to_prior_protocols(self) -> None:
        expected_counts = {10: (83, 44), 11: (101, 46)}
        self.assertEqual(len(RAW_CATALOGS), len(expected_counts))
        for path, source_commit, protocol in RAW_CATALOGS:
            catalog = json.loads(path.read_text())
            self.assertEqual(catalog["source_commit"], source_commit)
            self.assertEqual(catalog["protocol"], protocol)
            command_count, event_count = expected_counts[protocol]
            self.assertEqual(len(catalog["commands"]), command_count)
            self.assertEqual(len(catalog["events"]), event_count)

    def test_security_fixture_requires_local_denial_and_no_wire_write(self) -> None:
        cases = {case["name"]: case for case in self.fixtures["fake_cases"]}
        case = cases["provider-authority-default-denied-no-write"]
        self.assertEqual(case["adapter"]["op"], "authority-denied")
        self.assertEqual(case["server"]["behavior"], "no-write")
        self.assertEqual(case["expect"]["value"], {"denied": True})

    def test_presence_fixtures_define_literal_wire_shapes(self) -> None:
        cases = {case["name"]: case for case in self.fixtures["fake_cases"]}
        self.assertEqual(
            cases["optional-nullable-request-omitted"]["server"]["expect_request"],
            {"cmd": "set-client-info"},
        )
        self.assertEqual(
            cases["optional-nullable-request-null"]["server"]["expect_request"],
            {"cmd": "set-client-info", "name": None},
        )
        self.assertEqual(
            cases["optional-nullable-request-value"]["server"]["expect_request"],
            {"cmd": "set-client-info", "name": "conformance-client"},
        )
        self.assertTrue(
            cases["required-nullable-response-missing"]["server"]["omit_lifecycle"]
        )
        self.assertNotIn(
            "name",
            cases["required-nullable-event-missing"]["server"]["after_ack"][0],
        )
        self.assertEqual(
            cases["optional-non-null-response-null"]["server"][
                "capabilities_presence"
            ],
            "null",
        )
        self.assertIsNone(
            cases["optional-non-null-event-null"]["server"]["after_ack"][0][
                "colors"
            ]
        )

    def test_live_lifecycle_covers_every_required_transition(self) -> None:
        cases = {case["name"]: case for case in self.fixtures["real_cases"]}
        expected = cases["headless-lifecycle"]["expect"]["value"]
        self.assertEqual(
            set(expected),
            {
                "identified",
                "workspace_created",
                "terminal_created",
                "marker_sent",
                "wait_matched",
                "read_contains_marker",
                "stream_ordered",
                "renamed",
                "closed",
                "disappeared",
            },
        )
        self.assertTrue(all(expected.values()))


class MatchingTests(unittest.TestCase):
    def test_partial_match_allows_extra_fields_but_not_missing_fields(self) -> None:
        self.assertTrue(
            partial_match(
                {"value": {"protocol": 10, "extra": True}, "extra": "ok"},
                {"value": {"protocol": 10}},
            )
        )
        self.assertFalse(partial_match({"value": {}}, {"value": {"protocol": 10}}))

    def test_expected_error_category_is_checked(self) -> None:
        case = {"expect_error": "timeout"}
        assert_case_response(
            case,
            {"ok": False, "error": {"kind": "timeout", "message": "late"}},
        )
        with self.assertRaises(ConformanceFailure):
            assert_case_response(
                case,
                {"ok": False, "error": {"kind": "transport", "message": "late"}},
            )


class NoWriteServerTests(unittest.TestCase):
    def test_clean_connect_and_close_records_no_bytes(self) -> None:
        with FakeServer({"behavior": "no-write"}) as server:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.connect(str(server.socket_path))
            connection.close()
            self.assertTrue(server.done.wait(timeout=1))
            self.assertFalse(server.bytes_received.is_set())

    def test_any_request_byte_fails_the_server(self) -> None:
        with self.assertRaises(ConformanceFailure):
            with FakeServer({"behavior": "no-write"}) as server:
                connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                connection.connect(str(server.socket_path))
                connection.sendall(b"{")
                connection.close()
                self.assertTrue(server.done.wait(timeout=1))


class RequestShapeServerTests(unittest.TestCase):
    def test_identify_then_exact_request_can_share_one_connection(self) -> None:
        spec = {
            "behavior": "request-shape",
            "expect_request": {"cmd": "set-client-info", "name": None},
        }
        with FakeServer(spec) as server:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.connect(str(server.socket_path))
            stream = connection.makefile("rwb")
            stream.write(b'{"id":1,"cmd":"identify"}\n')
            stream.flush()
            self.assertEqual(json.loads(stream.readline())["id"], 1)
            stream.write(b'{"id":2,"cmd":"set-client-info","name":null}\n')
            stream.flush()
            self.assertEqual(
                json.loads(stream.readline()),
                {"id": 2, "ok": True, "data": {}},
            )
            stream.close()
            connection.close()
            self.assertTrue(server.done.wait(timeout=1))

    def test_extra_request_field_fails_exact_shape_check(self) -> None:
        spec = {
            "behavior": "request-shape",
            "expect_request": {"cmd": "set-client-info"},
        }
        with self.assertRaisesRegex(ConformanceFailure, "typed request shape mismatch"):
            with FakeServer(spec) as server:
                connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                connection.connect(str(server.socket_path))
                connection.sendall(
                    b'{"id":1,"cmd":"set-client-info","name":null}\n'
                )
                connection.close()
                self.assertTrue(server.done.wait(timeout=1))


class StreamNegotiationServerTests(unittest.TestCase):
    def test_identify_then_stream_can_share_one_connection(self) -> None:
        with FakeServer({"behavior": "stream"}) as server:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.connect(str(server.socket_path))
            stream = connection.makefile("rwb")
            stream.write(b'{"id":1,"cmd":"identify"}\n')
            stream.flush()
            identity = json.loads(stream.readline())
            self.assertEqual(identity["id"], 1)
            self.assertEqual(identity["data"]["protocol"], 12)

            stream.write(
                b'{"id":2,"cmd":"subscribe","tree_events":"deltas"}\n'
            )
            stream.flush()
            acknowledgement = json.loads(stream.readline())
            self.assertEqual(acknowledgement, {"id": 2, "ok": True, "data": {}})
            stream.close()
            connection.close()
            self.assertTrue(server.done.wait(timeout=1))


if __name__ == "__main__":
    unittest.main()
