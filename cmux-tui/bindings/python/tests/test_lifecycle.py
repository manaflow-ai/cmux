from __future__ import annotations

import threading
import unittest
from typing import Callable, Iterable

from cmux.raw import AuthorityError, CmuxClient, CommandError, CursorStyle, ProtocolError
from cmux.raw import TimeoutError as CmuxTimeoutError

from support import UnixJsonServer, receive_frame, send_frame


class LifecycleTests(unittest.TestCase):
    def assert_typed_field_rejected_without_write(
        self,
        *,
        protocol: int,
        capabilities: Iterable[str] = (),
        expected: str,
        invoke: Callable[[CmuxClient], object],
    ) -> None:
        observed = []
        accepted = threading.Event()

        def handler(connection, _index):
            accepted.set()
            request = receive_frame(connection)
            observed.append(request)
            send_frame(connection, {"id": request["id"], "ok": True, "data": {}})

        with UnixJsonServer(handler) as server:
            client = CmuxClient(server.path)
            self.assertTrue(accepted.wait(1), "fake server did not accept client")
            client._protocol = protocol
            client._capabilities = set(capabilities)
            try:
                with self.assertRaises(ProtocolError) as raised:
                    invoke(client)
            finally:
                client.close()

        self.assertIn(expected, str(raised.exception))
        self.assertEqual(observed, [])

    def test_provider_authority_is_denied_before_typed_or_known_raw_writes(
        self,
    ) -> None:
        observed = []
        accepted = threading.Event()

        def handler(connection, _index):
            accepted.set()
            chunks = bytearray()
            while True:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                chunks.extend(chunk)
            observed.append(bytes(chunks))

        with UnixJsonServer(handler) as server:
            client = CmuxClient(server.path)
            self.assertTrue(accepted.wait(1), "fake server did not accept client")
            with self.assertRaises(AuthorityError) as typed:
                client.mark_workspaces_provider_managed("provider.example")
            with self.assertRaises(AuthorityError) as raw:
                client.request(
                    "mark-workspaces-provider-managed",
                    authority="provider.example",
                )
            client.close()

        self.assertEqual(typed.exception.command, "mark-workspaces-provider-managed")
        self.assertEqual(typed.exception.authority, "provider-authority")
        self.assertEqual(raw.exception.command, "mark-workspaces-provider-managed")
        self.assertEqual(observed, [b""])

    def test_provider_authority_can_be_explicitly_enabled(self) -> None:
        observed = []

        def handler(connection, _index):
            request = receive_frame(connection)
            observed.append(request)
            send_frame(connection, {"id": request["id"], "ok": True, "data": {}})

        with UnixJsonServer(handler) as server:
            client = CmuxClient(server.path, allow_provider_authority=True)
            client._protocol = 10
            client._capabilities = {"provider-managed-workspace-authority-v2"}
            client.mark_workspaces_provider_managed("provider.example")
            client.close()

        self.assertEqual(
            observed[0]["cmd"],
            "mark-workspaces-provider-managed",
        )

    def test_raw_request_preserves_explicit_null(self) -> None:
        observed = []

        def handler(connection, _index):
            request = receive_frame(connection)
            observed.append(request)
            send_frame(
                connection,
                {"id": request["id"], "ok": True, "data": {"seen": True}},
            )

        with UnixJsonServer(handler) as server:
            with CmuxClient(server.path) as client:
                response = client.request("future-command", missing=None)

        self.assertTrue(response["data"]["seen"])
        self.assertIn("missing", observed[0])
        self.assertIsNone(observed[0]["missing"])

    def test_protocol_gated_request_fields_are_denied_before_write(self) -> None:
        cases = (
            (
                "send.paste",
                6,
                lambda client: client.send(1, text="hello", paste=True),
            ),
            (
                "run.key",
                8,
                lambda client: client.run(
                    command="true",
                    new_workspace=True,
                    key="workspace-key",
                ),
            ),
            (
                "set-default-colors.cursor_style",
                8,
                lambda client: client.set_default_colors(
                    cursor_style=CursorStyle.BLOCK
                ),
            ),
            (
                "close-workspace.key",
                6,
                lambda client: client.close_workspace(key="workspace-key"),
            ),
        )

        for field_name, protocol, invoke in cases:
            with self.subTest(field=field_name):
                self.assert_typed_field_rejected_without_write(
                    protocol=protocol,
                    expected=f"{field_name} requires protocol",
                    invoke=invoke,
                )

    def test_capability_gated_request_fields_are_denied_before_write(self) -> None:
        cases = (
            (
                "subscribe.surface",
                lambda client: client.subscribe(surface=1),
            ),
            (
                "move-workspace.key",
                lambda client: client.move_workspace(
                    1,
                    key="workspace-key",
                ),
            ),
            (
                "close-workspace.key",
                lambda client: client.close_workspace(key="workspace-key"),
            ),
            (
                "rename-workspace.key",
                lambda client: client.rename_workspace(
                    "renamed",
                    key="workspace-key",
                ),
            ),
        )

        for field_name, invoke in cases:
            with self.subTest(field=field_name):
                self.assert_typed_field_rejected_without_write(
                    protocol=10,
                    expected=f"{field_name} requires server capability",
                    invoke=invoke,
                )

    def test_omitted_newer_field_does_not_block_typed_command(self) -> None:
        observed = []

        def handler(connection, _index):
            request = receive_frame(connection)
            observed.append(request)
            send_frame(connection, {"id": request["id"], "ok": True, "data": {}})

        with UnixJsonServer(handler) as server:
            client = CmuxClient(server.path)
            client._protocol = 6
            client.send(1, text="hello")
            client.close()

        self.assertEqual(observed[0]["cmd"], "send")
        self.assertNotIn("paste", observed[0])

    def test_raw_request_preserves_field_level_forward_compatibility(self) -> None:
        observed = []

        def handler(connection, _index):
            request = receive_frame(connection)
            observed.append(request)
            send_frame(connection, {"id": request["id"], "ok": True, "data": {}})

        with UnixJsonServer(handler) as server:
            client = CmuxClient(server.path)
            client._protocol = 6
            client.request("send", surface=1, text="hello", paste=True)
            client.close()

        self.assertEqual(observed[0]["cmd"], "send")
        self.assertIs(observed[0]["paste"], True)

    def test_client_close_unblocks_a_stream_reader(self) -> None:
        stream_ready = threading.Event()

        def handler(connection, index):
            if index == 0:
                while connection.recv(1):
                    pass
                return
            request = receive_frame(connection)
            send_frame(connection, {"id": request["id"], "ok": True, "data": {}})
            stream_ready.set()
            while connection.recv(1):
                pass

        with UnixJsonServer(handler) as server:
            client = CmuxClient(server.path)
            client._protocol = 10
            stream = client.subscribe()
            stream_ready.wait(1)
            outcome = []
            read_started = threading.Event()

            def read() -> None:
                try:
                    stream._next(before_wait=read_started.set)
                except BaseException as error:
                    outcome.append(error)

            reader = threading.Thread(target=read)
            reader.start()
            self.assertTrue(read_started.wait(1), "stream reader did not start")
            client.close()
            reader.join(timeout=1)

        self.assertFalse(reader.is_alive())
        self.assertEqual(len(outcome), 1)
        self.assertIsInstance(outcome[0], StopIteration)

    def test_pre_ack_event_buffer_is_bounded(self) -> None:
        def handler(connection, index):
            if index == 0:
                while connection.recv(1):
                    pass
                return
            request = receive_frame(connection)
            for number in range(3):
                send_frame(
                    connection,
                    {"event": f"future-event-{number}", "value": number},
                )
            send_frame(connection, {"id": request["id"], "ok": True, "data": {}})

        with UnixJsonServer(handler) as server:
            client = CmuxClient(server.path, max_pre_ack_events=2)
            client._protocol = 10
            with self.assertRaisesRegex(ProtocolError, "before its acknowledgement"):
                client.subscribe()
            client.close()

    def test_inbound_json_lines_are_bounded(self) -> None:
        def handler(connection, _index):
            receive_frame(connection)
            connection.sendall(b'{"id":1,"ok":true,"data":"' + b"x" * 300 + b'"}\n')

        with UnixJsonServer(handler) as server:
            client = CmuxClient(server.path, max_line_bytes=128)
            with self.assertRaisesRegex(ProtocolError, "exceeds"):
                client.request("large-response")
            client.close()

    def test_typed_command_preserves_server_error_text(self) -> None:
        def handler(connection, _index):
            request = receive_frame(connection)
            send_frame(
                connection,
                {
                    "id": request["id"],
                    "ok": False,
                    "error": "surface 99 belongs to another generation",
                },
            )

        with UnixJsonServer(handler) as server:
            client = CmuxClient(server.path)
            client._protocol = 10
            with self.assertRaises(CommandError) as raised:
                client.close_surface(99)
            client.close()

        self.assertEqual(
            raised.exception.message,
            "surface 99 belongs to another generation",
        )

    def test_command_timeout_has_a_distinct_exception(self) -> None:
        release = threading.Event()

        def handler(connection, _index):
            receive_frame(connection)
            release.wait(1)

        with UnixJsonServer(handler) as server:
            client = CmuxClient(server.path, timeout=0.02)
            with self.assertRaises(CmuxTimeoutError):
                client.request("slow-command")
            release.set()
            client.close()


if __name__ == "__main__":
    unittest.main()
