from __future__ import annotations

import asyncio
import json
import threading
import unittest

import cmux
import cmux.aio
import cmux.raw
from cmux import (
    Client,
    ExternalMachineSpecifier,
    MachineId,
    MutationIndeterminateError,
    PaneId,
    ProviderCredential,
    ProviderNoticeId,
    ProviderScopeId,
    RendererGrant,
    ResourceError,
    ScreenId,
    SessionId,
    TerminalId,
    TabId,
    Unknown,
    WorkspaceId,
    exact,
    shell,
    shell_executable,
)
from cmux.options import RunOptions

from support import UnixJsonServer, send_frame


HEX_A = "a" * 32
HEX_B = "b" * 32
HEX_C = "c" * 32
SESSION = SessionId(f"session_{HEX_A}")
WORKSPACE = WorkspaceId(f"ws_{HEX_B}")
TERMINAL = TerminalId(f"term_{HEX_C}")
MACHINE = MachineId(f"machine_{HEX_A}")
SCREEN = ScreenId(f"screen_{HEX_C}")
PANE = PaneId(f"pane_{HEX_A}")
TAB = TabId(f"tab_{HEX_B}")
PROVIDER_SCOPE = ProviderScopeId(f"provider_scope_{HEX_A}")
PROVIDER_NOTICE = ProviderNoticeId(f"provider_notice_{HEX_B}")


def frames(connection):
    source = connection.makefile("rb")
    while True:
        line = source.readline()
        if not line:
            return
        yield json.loads(line)


def ok(connection, request, result):
    send_frame(
        connection,
        {
            "protocol": "cmux.protocol/1",
            "type": "response",
            "id": request["id"],
            "ok": True,
            "result": result,
        },
    )


class ResourceApiTests(unittest.TestCase):
    def test_root_is_resource_api_and_legacy_is_raw_only(self) -> None:
        self.assertIs(cmux.Client, Client)
        self.assertFalse(hasattr(cmux, "CmuxClient"))
        self.assertFalse(hasattr(cmux, "MISSING"))
        self.assertTrue(hasattr(cmux.raw, "CmuxClient"))
        self.assertTrue(hasattr(cmux.raw, "MISSING"))
        self.assertFalse(hasattr(cmux, "SidebarPlugin"))
        self.assertFalse(hasattr(cmux, "SidebarPluginId"))

    def test_exact_shell_and_chosen_shell_keep_exact_wire_shape(self) -> None:
        observed = []

        def handler(connection, _index):
            for request in frames(connection):
                observed.append(request)
                ok(
                    connection,
                    request,
                    {
                        "value": {
                            "kind": "terminal",
                            "workspace_id": str(WORKSPACE),
                            "screen_id": str(SCREEN),
                            "pane_id": str(PANE),
                            "tab_id": str(TAB),
                            "terminal_id": str(TERMINAL),
                        },
                        "generation": "generation-a",
                        "revision": "18446744073709551615",
                        "replayed": False,
                    },
                )

        random_values = iter((HEX_A, HEX_B, HEX_C))
        with UnixJsonServer(handler) as server:
            with Client(
                server.path,
                random_hex_128=lambda: next(random_values),
            ) as client:
                workspace = client.session(SESSION).workspace(WORKSPACE)
                first = workspace.run(RunOptions(exact(["printf", "%s", "$HOME"])))
                workspace.run(RunOptions(shell("printf %s \"$HOME\"")))
                workspace.run(
                    RunOptions(shell_executable("/bin/zsh", "echo $(uname)"))
                )

        self.assertIsNotNone(first.value.terminal)
        self.assertEqual(first.value.terminal.id, TERMINAL)
        self.assertEqual(first.revision, "18446744073709551615")
        self.assertEqual(
            [item["idempotency_key"] for item in observed],
            [f"py-{HEX_A}", f"py-{HEX_B}", f"py-{HEX_C}"],
        )
        common = {
            "machine": "current",
            "session": str(SESSION),
            "workspace": str(WORKSPACE),
        }
        self.assertEqual(
            observed[0]["params"],
            {**common, "argv": ["printf", "%s", "$HOME"]},
        )
        self.assertEqual(
            observed[1]["params"],
            {**common, "shell": "printf %s \"$HOME\""},
        )
        self.assertEqual(
            observed[2]["params"],
            {**common, "argv": ["/bin/zsh", "-lc", "echo $(uname)"]},
        )

    def test_structured_error_and_stream_cancel_are_connection_local(self) -> None:
        observed = []

        def handler(connection, _index):
            for request in frames(connection):
                observed.append(request)
                if request["operation"] == "session.ping":
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/1",
                            "type": "response",
                            "id": request["id"],
                            "ok": False,
                            "error": {
                                "code": "selector.not_found",
                                "message": "session is gone",
                                "details": {"selector": request["params"]["session"]},
                                "retryable": False,
                            },
                        },
                    )
                elif request["operation"] == "session.events":
                    ok(
                        connection,
                        request,
                        {"stream_id": request["params"]["stream_id"]},
                    )
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/1",
                            "type": "stream_item",
                            "stream_id": request["params"]["stream_id"],
                            "sequence": "18446744073709551615",
                            "item": {"kind": "changed", "data": {"ok": True}},
                        },
                    )
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/1",
                            "type": "stream_item",
                            "stream_id": request["params"]["stream_id"],
                            "sequence": "18446744073709551614",
                            "item": {"kind": "buffered"},
                        },
                    )
                else:
                    ok(connection, request, {})

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                session = client.session(SESSION)
                with self.assertRaises(ResourceError) as raised:
                    session.ping()
                stream = session.events()
                item = next(stream)
                stream.cancel()
                with self.assertRaises(StopIteration):
                    next(stream)

        self.assertEqual(raised.exception.code, "selector.not_found")
        self.assertFalse(raised.exception.retryable)
        self.assertEqual(item.sequence, "18446744073709551615")
        self.assertIsInstance(item.item, Unknown)
        self.assertEqual(item.item.kind, "changed")
        self.assertEqual(
            item.item.raw,
            {"kind": "changed", "data": {"ok": True}},
        )
        cancel = observed[-1]
        self.assertEqual(cancel["operation"], "stream.cancel")
        self.assertNotIn("idempotency_key", cancel)
        self.assertEqual(
            cancel["params"],
            {
                "machine": "current",
                "session": str(SESSION),
                "stream": stream.id,
            },
        )

    def test_optional_fields_and_expected_revision_reach_the_wire(self) -> None:
        observed = []

        def handler(connection, _index):
            for request in frames(connection):
                observed.append(request)
                if request["operation"] in {"notification.list", "agent.list"}:
                    ok(connection, request, [])
                elif request["operation"] == "provider_notice.acknowledge":
                    ok(connection, request, {})
                else:
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/1",
                            "type": "response",
                            "id": request["id"],
                            "ok": False,
                            "error": {
                                "code": "operation.failed",
                                "message": "fixture stop",
                                "details": {
                                    "operation": request["operation"],
                                    "reason": "fixture",
                                },
                                "retryable": False,
                            },
                        },
                    )

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                with self.assertRaises(ResourceError):
                    client.machine(MACHINE).rename(
                        "renamed",
                        confirm_close=True,
                        expected_revision="7",
                        idempotency_key="machine-rename",
                    )
                screen = client.session(SESSION).workspace(WORKSPACE).screen(SCREEN)
                with self.assertRaises(ResourceError):
                    screen.undo_layout(
                        confirm_close=True,
                        expected_revision="8",
                        idempotency_key="screen-undo",
                    )
                session = client.session(SESSION)
                self.assertEqual(session.list_notifications(limit=7), [])
                self.assertEqual(
                    session.list_agents(
                        terminal_id=TERMINAL,
                        state="working",
                    ),
                    [],
                )
                client.provider_scope(PROVIDER_SCOPE).notice(
                    PROVIDER_NOTICE
                ).acknowledge("18446744073709551615")

        by_operation = {item["operation"]: item for item in observed}
        self.assertEqual(
            by_operation["machine.rename"]["params"],
            {
                "machine": str(MACHINE),
                "name": "renamed",
                "confirm_close": True,
                "expected_revision": "7",
            },
        )
        self.assertEqual(
            by_operation["screen.layout.undo"]["params"]["confirm_close"],
            True,
        )
        self.assertEqual(
            by_operation["screen.layout.undo"]["params"]["expected_revision"],
            "8",
        )
        self.assertEqual(
            by_operation["notification.list"]["params"]["limit"],
            7,
        )
        self.assertEqual(
            by_operation["agent.list"]["params"]["terminal_id"],
            str(TERMINAL),
        )
        self.assertEqual(
            by_operation["agent.list"]["params"]["state"],
            "working",
        )
        self.assertEqual(
            by_operation["provider_notice.acknowledge"]["params"]["sequence"],
            "18446744073709551615",
        )

    def test_indeterminate_mutation_is_typed_and_never_retried(self) -> None:
        observed = []

        def handler(connection, _index):
            for request in frames(connection):
                observed.append(request)
                send_frame(
                    connection,
                    {
                        "protocol": "cmux.protocol/1",
                        "type": "response",
                        "id": request["id"],
                        "ok": False,
                        "error": {
                            "code": "mutation.indeterminate",
                            "message": "external effect may have completed",
                            "details": {
                                "idempotency_key": request["idempotency_key"],
                                "operation": request["operation"],
                                "recovery": (
                                    "inspect_state_then_retry_with_new_key"
                                ),
                            },
                            "retryable": False,
                        },
                    },
                )

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                with self.assertRaises(MutationIndeterminateError) as raised:
                    client.machine(MACHINE).rename(
                        "external",
                        idempotency_key="external-rename",
                    )

        self.assertEqual(len(observed), 1)
        self.assertEqual(raised.exception.code, "mutation.indeterminate")
        self.assertFalse(raised.exception.retryable)
        self.assertEqual(
            raised.exception.details,
            {
                "idempotency_key": "external-rename",
                "operation": "machine.rename",
                "recovery": "inspect_state_then_retry_with_new_key",
            },
        )

    def test_secrets_are_one_use_and_redacted(self) -> None:
        specifier = ExternalMachineSpecifier("provider://machine-secret")
        self.assertNotIn("machine-secret", repr(specifier))
        self.assertEqual(specifier.take(), "provider://machine-secret")
        with self.assertRaises(RuntimeError):
            specifier.take()

        credential = ProviderCredential("token", "provider-secret")
        self.assertNotIn("provider-secret", repr(credential))
        self.assertEqual(
            credential.to_params(),
            {"name": "token", "value": "provider-secret"},
        )
        with self.assertRaises(RuntimeError):
            credential.to_params()

        grant = RendererGrant(
            "renderer-secret",
            endpoint="unix:///tmp/renderer.sock",
            terminal_id=TERMINAL,
            rights=("render",),
            ttl_ms=1_000,
        )
        self.assertNotIn("renderer-secret", repr(grant))
        self.assertEqual(grant.take(), "renderer-secret")
        with self.assertRaises(RuntimeError):
            grant.take()

    def test_aio_cancellation_closes_reader_and_executor_threads(self) -> None:
        request_seen = threading.Event()

        def handler(connection, _index):
            next(frames(connection))
            request_seen.set()
            while connection.recv(1):
                pass

        async def exercise(path):
            client = cmux.aio.Client(path)
            task = asyncio.create_task(client.list_machines())
            await asyncio.to_thread(request_seen.wait, 1)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            self.assertTrue(client.closed)

        with UnixJsonServer(handler) as server:
            asyncio.run(exercise(server.path))

        leaked = [
            thread.name
            for thread in threading.enumerate()
            if thread.name.startswith(("cmux-aio", "cmux-resource-reader-"))
        ]
        self.assertEqual(leaked, [])


if __name__ == "__main__":
    unittest.main()
