from __future__ import annotations

import asyncio
import json
import threading
import unittest

import cmux
import cmux._protocol as resource_protocol
import cmux.aio
import cmux.raw
from cmux import (
    CancelledError,
    CancellationToken,
    Client,
    CmuxConnectionError,
    ConnectedClientId,
    MachineId,
    MutationIndeterminateError,
    MutationTransportError,
    PairingRequestId,
    PaneId,
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
from cmux.options import (
    CreateBrowserOptions,
    CreatePaneOptions,
    CreateScreenOptions,
    CreateTerminalOptions,
    CreateWorkspaceOptions,
    RequestOptions,
    RunOptions,
    SplitPaneOptions,
)

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
CONNECTED_CLIENT = ConnectedClientId(f"client_{HEX_C}")
PAIRING_REQUEST = PairingRequestId(f"pairing_{HEX_A}")


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

    def test_every_created_path_operation_sends_a_validated_correlation_key(
        self,
    ) -> None:
        with self.assertRaises(ValueError):
            CreateWorkspaceOptions(correlation_key="")
        with self.assertRaises(ValueError):
            CreateScreenOptions(correlation_key="🔥" * 33)

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

        correlation_key = "creation-correlation"
        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                session = client.session(SESSION)
                workspace = session.workspace(WORKSPACE)
                screen = workspace.screen(SCREEN)
                pane = screen.pane(PANE)
                calls = (
                    lambda: session.create_workspace(
                        CreateWorkspaceOptions(
                            correlation_key=correlation_key,
                        )
                    ),
                    lambda: workspace.run(
                        RunOptions(
                            exact(["true"]),
                            correlation_key=correlation_key,
                        )
                    ),
                    lambda: workspace.create_screen(
                        CreateScreenOptions(
                            correlation_key=correlation_key,
                        )
                    ),
                    lambda: screen.create_pane(
                        CreatePaneOptions(
                            correlation_key=correlation_key,
                        )
                    ),
                    lambda: pane.run(
                        RunOptions(
                            exact(["true"]),
                            correlation_key=correlation_key,
                        )
                    ),
                    lambda: pane.split(
                        SplitPaneOptions(
                            "right",
                            correlation_key=correlation_key,
                        )
                    ),
                    lambda: pane.create_terminal_tab(
                        CreateTerminalOptions(
                            correlation_key=correlation_key,
                        )
                    ),
                    lambda: pane.create_browser_tab(
                        CreateBrowserOptions(
                            "https://example.com",
                            correlation_key=correlation_key,
                        )
                    ),
                )
                for call in calls:
                    with self.assertRaises(ResourceError):
                        call()

        self.assertEqual(
            [request["operation"] for request in observed],
            [
                "workspace.create",
                "workspace.run",
                "screen.create",
                "pane.create",
                "pane.run",
                "pane.split",
                "tab.create_terminal",
                "tab.create_browser",
            ],
        )
        self.assertTrue(
            all(
                request["params"]["correlation_key"] == correlation_key
                for request in observed
            )
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
                elif request["operation"] == "screen.layout.undo":
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/1",
                            "type": "response",
                            "id": request["id"],
                            "ok": False,
                            "error": {
                                "code": "confirmation.required",
                                "message": "layout preview changed",
                                "details": {
                                    "confirmation_token": "fresh-preview",
                                    "revision": "9",
                                    "closes_panes": [str(PANE)],
                                },
                                "retryable": False,
                            },
                        },
                    )
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
                screen = client.session(SESSION).workspace(WORKSPACE).screen(SCREEN)
                with self.assertRaises(ValueError):
                    screen.undo_layout(confirm_close=True)
                with self.assertRaises(
                    cmux.ConfirmationRequiredError
                ) as confirmation:
                    screen.undo_layout(
                        confirm_close=True,
                        confirmation_token="stale-preview",
                        expected_revision="8",
                        idempotency_key="screen-undo",
                    )
                self.assertEqual(
                    confirmation.exception.details.confirmation_token,
                    "fresh-preview",
                )
                self.assertEqual(
                    confirmation.exception.details.revision,
                    "9",
                )
                self.assertEqual(
                    confirmation.exception.details.closes_panes,
                    (PANE,),
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

        by_operation = {item["operation"]: item for item in observed}
        self.assertEqual(
            by_operation["screen.layout.undo"]["params"]["confirm_close"],
            True,
        )
        self.assertEqual(
            by_operation["screen.layout.undo"]["params"]["expected_revision"],
            "8",
        )
        self.assertEqual(
            by_operation["screen.layout.undo"]["params"]["confirmation_token"],
            "stale-preview",
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
                    client.session(SESSION).workspace(WORKSPACE).rename(
                        "renamed",
                        idempotency_key="workspace-rename",
                    )

        self.assertEqual(len(observed), 1)
        self.assertEqual(raised.exception.code, "mutation.indeterminate")
        self.assertFalse(raised.exception.retryable)
        self.assertEqual(
            raised.exception.details,
            {
                "idempotency_key": "workspace-rename",
                "operation": "workspace.rename",
                "recovery": "inspect_state_then_retry_with_new_key",
            },
        )

    def test_renderer_grant_is_one_use_and_redacted(self) -> None:
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

    def test_catalog_results_decode_to_exact_types(self) -> None:
        results = {
            "session.ping": {
                "alive": True,
                "cursor": {"generation": "generation-a", "revision": "9"},
            },
            "session.reload_config": {
                "reloaded": True,
                "warnings": ["kept existing shell"],
            },
            "session.shutdown": {"accepted": True},
            "session.terminal_defaults.update": {
                "foreground": "#ffffff",
                "cursor_style": "bar",
                "palette": {"0": "#000000"},
            },
            "terminal.screen.read": {
                "text": "hello",
                "cols": 80,
                "rows": 24,
                "cursor_row": 2,
                "cursor_col": 5,
                "cursor_visible": True,
                "extra": {"source": "fixture"},
            },
            "terminal.state.read": {
                "state_base64": "AP8=",
                "cols": 80,
                "rows": 24,
            },
            "terminal.history.read": {
                "start": "7",
                "next": None,
                "rows": [
                    {
                        "row": 0,
                        "runs": [
                            {
                                "text": "hello",
                                "fg": None,
                                "bg": None,
                                "attrs": 0,
                            }
                        ],
                    }
                ],
            },
            "terminal.wait": {"matched": True, "text": "ready"},
            "terminal.copy": {"mode": "screen", "text": "hello"},
            "terminal.process.get": {
                "pid": 42,
                "executable": "/bin/zsh",
                "argv": ["/bin/zsh", "-l"],
                "cwd": "/tmp",
                "children": [43],
            },
            "terminal.viewer.resize": {
                "accepted": True,
                "size": {"cols": 100, "rows": 30},
            },
            "terminal.viewer.release": {},
            "terminal.renderer_grant.create": {
                "endpoint": "unix:///tmp/renderer.sock",
                "terminal_id": str(TERMINAL),
                "token": "renderer-secret",
                "rights": ["render"],
                "ttl_ms": 1_000,
            },
            "client.cell_pixels.set": {
                "width_px": 9,
                "height_px": 18,
                "resized_terminals": [str(TERMINAL)],
                "failures": {},
            },
            "client.detach": {},
            "terminal.input.write": {},
            "pairing_request.resolve": {
                "pairing_request": {
                    "id": str(PAIRING_REQUEST),
                    "session_id": str(SESSION),
                    "peer": "iPhone",
                    "code": "123456",
                    "expires_in_seconds": "60",
                    "status": "accepted",
                }
            },
        }
        mutations = {
            "session.reload_config",
            "session.shutdown",
            "session.terminal_defaults.update",
            "terminal.input.write",
            "pairing_request.resolve",
        }

        def handler(connection, _index):
            for request in frames(connection):
                value = results[request["operation"]]
                if request["operation"] in mutations:
                    value = {
                        "value": value,
                        "generation": "generation-a",
                        "revision": "10",
                        "replayed": False,
                    }
                ok(connection, request, value)

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                session = client.session(SESSION)
                terminal = session.terminal(TERMINAL)
                self.assertIsInstance(session.ping(), cmux.PingResult)
                self.assertIsInstance(
                    session.reload_config(idempotency_key="reload"),
                    cmux.MutationResult,
                )
                self.assertTrue(
                    session.shutdown(idempotency_key="shutdown").value.accepted
                )
                defaults = session.update_terminal_defaults(
                    {"foreground": "#ffffff"},
                    idempotency_key="defaults",
                ).value
                self.assertEqual(defaults.cursor_style, "bar")
                screen = terminal.read_screen()
                self.assertIsInstance(screen, cmux.TerminalScreenResult)
                self.assertEqual(screen.extra, {"source": "fixture"})
                self.assertEqual(terminal.read_state().state, b"\x00\xff")
                self.assertEqual(
                    terminal.read_history().rows[0].runs[0].text,
                    "hello",
                )
                self.assertTrue(
                    terminal.wait(cmux.TerminalWaitOptions("ready")).matched
                )
                self.assertEqual(terminal.copy().mode, "screen")
                self.assertEqual(terminal.process().children, (43,))
                self.assertEqual(
                    terminal.resize_viewer(cmux.ViewerSizeOptions(100, 30)).size.cols,
                    100,
                )
                self.assertIsNone(terminal.release_viewer())
                grant = terminal.create_renderer_grant()
                self.assertEqual(grant.terminal_id, TERMINAL)
                receipt = terminal.write(
                    "hello",
                    idempotency_key="write",
                )
                self.assertIsNone(receipt.value)
                connected = session.connected_client(CONNECTED_CLIENT)
                pixels = connected.set_cell_pixels(9, 18)
                self.assertEqual(pixels.resized_terminals, (TERMINAL,))
                self.assertIsNone(connected.detach())
                resolution = session.pairing_request(
                    PAIRING_REQUEST
                ).resolve(
                    "accept",
                    idempotency_key="pair",
                )
                self.assertEqual(
                    resolution.value.pairing_request.status,
                    "accepted",
                )

    def test_catalog_results_reject_unknown_sibling_fields(self) -> None:
        def handler(connection, _index):
            request = next(frames(connection))
            ok(
                connection,
                request,
                {
                    "text": "",
                    "cols": 80,
                    "rows": 24,
                    "cursor_row": 0,
                    "cursor_col": 0,
                    "cursor_visible": True,
                    "future": "must use extra",
                },
            )

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                with self.assertRaises(cmux.ProtocolError):
                    client.session(SESSION).terminal(TERMINAL).read_screen()

    def test_exact_mutation_key_is_exposed_on_disconnect(self) -> None:
        observed = []

        def handler(connection, _index):
            observed.append(next(frames(connection)))

        with UnixJsonServer(handler) as server:
            with Client(
                server.path,
                random_hex_128=lambda: HEX_B,
            ) as client:
                with self.assertRaises(MutationTransportError) as raised:
                    client.session(SESSION).workspace(WORKSPACE).rename("renamed")
        self.assertEqual(raised.exception.operation, "workspace.rename")
        self.assertEqual(raised.exception.idempotency_key, f"py-{HEX_B}")
        self.assertIsInstance(raised.exception.cause, CmuxConnectionError)

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                with self.assertRaises(MutationTransportError) as explicit:
                    client.session(SESSION).workspace(WORKSPACE).rename(
                        "renamed",
                        idempotency_key="caller-owned",
                    )
        self.assertEqual(explicit.exception.operation, "workspace.rename")
        self.assertEqual(explicit.exception.idempotency_key, "caller-owned")
        self.assertIsInstance(explicit.exception.cause, CmuxConnectionError)
        self.assertEqual(len(observed), 2)

    def test_creation_resolution_and_terminal_exit_wait_are_typed(self) -> None:
        def handler(connection, _index):
            requests = frames(connection)
            resolve = next(requests)
            self.assertEqual(
                resolve["operation"],
                "session.creation.resolve",
            )
            self.assertEqual(
                resolve["params"]["correlation_key"],
                "create-1",
            )
            ok(
                connection,
                resolve,
                {
                    "correlation_key": "create-1",
                    "state": "created",
                    "recovery": "none",
                    "created_path": {
                        "kind": "workspace",
                        "workspace_id": str(WORKSPACE),
                    },
                    "generation": "generation-a",
                    "revision": "7",
                },
            )

            pending = next(requests)
            self.assertEqual(pending["operation"], "terminal.wait_exit")
            self.assertEqual(pending["params"]["timeout_ms"], "0")
            ok(
                connection,
                pending,
                {
                    "state": "pending",
                    "terminal_id": str(TERMINAL),
                    "lifecycle": "running",
                    "revision": "8",
                },
            )

            exited = next(requests)
            self.assertEqual(exited["params"]["timeout_ms"], "250")
            ok(
                connection,
                exited,
                {
                    "state": "exited",
                    "terminal_id": str(TERMINAL),
                    "lifecycle": "exited",
                    "outcome": {
                        "kind": "signal",
                        "signal": 15,
                        "core_dumped": False,
                    },
                    "exited_at": "1000",
                    "revision": "9",
                },
            )

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                session = client.session(SESSION)
                resolution = session.creation.resolve("create-1")
                self.assertEqual(resolution.state, "created")
                self.assertEqual(
                    resolution.created_path.workspace.id,
                    WORKSPACE,
                )
                terminal = session.terminal(TERMINAL)
                self.assertIsInstance(
                    terminal.wait_exit(0),
                    cmux.TerminalWaitExitPending,
                )
                result = terminal.wait_exit(250)
                self.assertIsInstance(
                    result,
                    cmux.TerminalWaitExitExited,
                )
                self.assertIsInstance(
                    result.outcome,
                    cmux.TerminalExitSignal,
                )
                self.assertEqual(result.outcome.signal, 15)

    def test_terminal_exit_unions_reject_cross_variant_values(self) -> None:
        responses = [
            {
                "state": "pending",
                "terminal_id": str(TERMINAL),
                "lifecycle": "exited",
                "revision": "1",
            },
            {
                "state": "exited",
                "terminal_id": str(TERMINAL),
                "lifecycle": "exited",
                "outcome": {
                    "kind": "signal",
                    "signal": 0,
                    "core_dumped": False,
                },
                "exited_at": "1",
                "revision": "2",
            },
        ]

        def handler(connection, _index):
            request = next(frames(connection))
            ok(connection, request, responses.pop(0))

        for _ in range(2):
            with UnixJsonServer(handler) as server:
                with Client(server.path) as client:
                    with self.assertRaises(cmux.ProtocolError):
                        client.session(SESSION).terminal(
                            TERMINAL
                        ).wait_exit()

    def test_terminal_snapshot_lifecycle_invariants_are_strict(self) -> None:
        base = {
            "id": str(TERMINAL),
            "tab_id": str(TAB),
            "title": "fixture",
            "cols": 80,
            "rows": 24,
            "running": True,
            "lifecycle": "running",
        }
        invalid = [
            {**base, "running": False},
            {
                **base,
                "running": False,
                "lifecycle": "exited",
            },
        ]

        def handler(connection, _index):
            request = next(frames(connection))
            ok(connection, request, invalid.pop(0))

        for _ in range(2):
            with UnixJsonServer(handler) as server:
                with Client(server.path) as client:
                    with self.assertRaises(cmux.ProtocolError):
                        client.session(SESSION).terminal(TERMINAL).refresh()

        exited = {
            **base,
            "running": False,
            "lifecycle": "exited",
            "exit": {
                "outcome": {"kind": "exit", "code": 0},
                "exited_at": "1000",
                "revision": "9",
            },
        }

        def exited_handler(connection, _index):
            request = next(frames(connection))
            ok(connection, request, exited)

        with UnixJsonServer(exited_handler) as server:
            with Client(server.path) as client:
                snapshot = client.session(SESSION).terminal(TERMINAL).refresh()
        self.assertEqual(snapshot.lifecycle, "exited")
        self.assertIsInstance(snapshot.exit.outcome, cmux.TerminalExitCode)

    def test_sync_request_options_apply_one_call_deadline(self) -> None:
        def handler(connection, _index):
            requests = frames(connection)
            first = next(requests)
            self.assertEqual(first["operation"], "session.ping")
            ping = next(requests)
            ok(
                connection,
                ping,
                {
                    "alive": True,
                    "cursor": {
                        "generation": "generation-a",
                        "revision": "1",
                    },
                },
            )

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=1) as client:
                with self.assertRaises(cmux.TimeoutError):
                    client.with_request_options(
                        RequestOptions(timeout=0.02),
                        client.session(SESSION).ping,
                    )
                self.assertTrue(client.session(SESSION).ping().alive)

    def test_cancellation_before_and_after_mutation_dispatch_is_typed(self) -> None:
        def before_handler(connection, _index):
            request = next(frames(connection))
            self.assertEqual(request["operation"], "session.ping")
            ok(
                connection,
                request,
                {
                    "alive": True,
                    "cursor": {
                        "generation": "generation-a",
                        "revision": "1",
                    },
                },
            )

        cancellation = CancellationToken()
        cancellation.cancel()
        with UnixJsonServer(before_handler) as server:
            with Client(server.path) as client:
                with self.assertRaises(CancelledError) as raised:
                    client.with_request_options(
                        RequestOptions(cancellation=cancellation),
                        client.session(SESSION).workspace(WORKSPACE).rename,
                        "renamed",
                        idempotency_key="never-sent",
                    )
                self.assertFalse(raised.exception.dispatched)
                self.assertTrue(client.session(SESSION).ping().alive)

        request_seen = threading.Event()
        release = threading.Event()

        def after_handler(connection, _index):
            request = next(frames(connection))
            self.assertEqual(request["idempotency_key"], "cancel-key")
            request_seen.set()
            release.wait(1)

        cancellation = CancellationToken()

        def cancel_after_dispatch():
            request_seen.wait(1)
            cancellation.cancel()

        with UnixJsonServer(after_handler) as server:
            with Client(server.path) as client:
                cancel_thread = threading.Thread(
                    target=cancel_after_dispatch,
                )
                cancel_thread.start()
                with self.assertRaises(MutationTransportError) as raised:
                    client.with_request_options(
                        RequestOptions(cancellation=cancellation),
                        client.session(SESSION).workspace(WORKSPACE).rename,
                        "renamed",
                        idempotency_key="cancel-key",
                    )
                release.set()
                cancel_thread.join()
        self.assertEqual(raised.exception.operation, "workspace.rename")
        self.assertEqual(raised.exception.idempotency_key, "cancel-key")
        self.assertIsInstance(raised.exception.cause, CancelledError)

    def test_aio_active_stream_does_not_block_ping(self) -> None:
        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            stream_id = opened["params"]["stream_id"]
            ok(connection, opened, {"stream_id": stream_id})
            ping = next(requests)
            ok(
                connection,
                ping,
                {
                    "alive": True,
                    "cursor": {
                        "generation": "generation-a",
                        "revision": "1",
                    },
                },
            )
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/1",
                    "type": "stream_item",
                    "stream_id": stream_id,
                    "sequence": "1",
                    "item": {"kind": "future.event", "value": 1},
                },
            )
            canceled = next(requests)
            ok(connection, canceled, {})

        async def exercise(path):
            async with cmux.aio.Client(path) as client:
                stream = await client.session(SESSION).events()
                next_item = asyncio.create_task(stream.next(timeout=1))
                ping = await asyncio.wait_for(
                    client.session(SESSION).ping(),
                    timeout=1,
                )
                self.assertTrue(ping.alive)
                item = await next_item
                self.assertIsInstance(item.item, Unknown)
                await stream.cancel()

        with UnixJsonServer(handler) as server:
            asyncio.run(exercise(server.path))

    def test_session_delta_upserts_are_exact_typed_snapshots(self) -> None:
        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            stream_id = opened["params"]["stream_id"]
            ok(connection, opened, {"stream_id": stream_id})
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/1",
                    "type": "stream_item",
                    "stream_id": stream_id,
                    "sequence": "1",
                    "cursor": {
                        "generation": "generation-a",
                        "revision": "2",
                    },
                    "item": {
                        "kind": "delta",
                        "cursor": {
                            "generation": "generation-a",
                            "revision": "2",
                        },
                        "previous_revision": "1",
                        "revision": "2",
                        "changes": [
                            {
                                "kind": "upsert",
                                "sequence": 7,
                                "resource": "terminal",
                                "id": str(TERMINAL),
                                "value": {
                                    "id": str(TERMINAL),
                                    "tab_id": str(TAB),
                                    "title": "typed",
                                    "cwd": "/tmp",
                                    "cols": 80,
                                    "rows": 24,
                                    "running": True,
                                    "lifecycle": "running",
                                },
                            }
                        ],
                    },
                },
            )
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/1",
                    "type": "stream_item",
                    "stream_id": stream_id,
                    "sequence": "2",
                    "item": {"kind": "future.event", "opaque": True},
                },
            )
            canceled = next(requests)
            ok(connection, canceled, {})

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                stream = client.session(SESSION).events()
                event = next(stream).item
                self.assertIsInstance(event, cmux.SessionDelta)
                change = event.changes[0]
                self.assertIsInstance(change, cmux.ResourceUpsert)
                self.assertIsInstance(change.value, cmux.TerminalSnapshot)
                self.assertEqual(change.value.title, "typed")
                self.assertIsInstance(next(stream).item, Unknown)
                stream.cancel()

    def test_resource_stream_limits_cancel_and_isolate_control_requests(
        self,
    ) -> None:
        previous_messages = resource_protocol.MAX_STREAM_MESSAGES
        previous_bytes = resource_protocol.MAX_STREAM_BYTES
        try:
            for overflow_by_bytes in (False, True):
                resource_protocol.MAX_STREAM_MESSAGES = (
                    4 if overflow_by_bytes else 1
                )
                resource_protocol.MAX_STREAM_BYTES = (
                    256 if overflow_by_bytes else 4096
                )

                def handler(connection, _index):
                    requests = frames(connection)
                    opened = next(requests)
                    stream_id = opened["params"]["stream_id"]

                    def item(sequence, blob):
                        return {
                            "protocol": "cmux.protocol/1",
                            "type": "stream_item",
                            "stream_id": stream_id,
                            "sequence": str(sequence),
                            "item": {
                                "kind": "future.event",
                                "blob": blob,
                            },
                        }

                    send_frame(
                        connection,
                        item(
                            1,
                            "x" * (1024 if overflow_by_bytes else 1),
                        ),
                    )
                    if not overflow_by_bytes:
                        send_frame(connection, item(2, "y"))

                    canceled = next(requests)
                    self.assertEqual(
                        canceled["operation"],
                        "stream.cancel",
                    )
                    self.assertEqual(
                        canceled["params"]["stream"],
                        stream_id,
                    )
                    ok(connection, canceled, {})
                    ok(connection, opened, {"stream_id": stream_id})

                    ping = next(requests)
                    self.assertEqual(ping["operation"], "session.ping")
                    ok(
                        connection,
                        ping,
                        {
                            "alive": True,
                            "cursor": {
                                "generation": "generation-a",
                                "revision": "1",
                            },
                        },
                    )

                with UnixJsonServer(handler) as server:
                    with Client(server.path) as client:
                        stream = client.session(SESSION).events()
                        with self.assertRaises(cmux.StreamError):
                            next(stream)
                        self.assertTrue(
                            client.session(SESSION).ping().alive
                        )
        finally:
            resource_protocol.MAX_STREAM_MESSAGES = previous_messages
            resource_protocol.MAX_STREAM_BYTES = previous_bytes

    def test_aio_stream_timeout_keeps_stream_open(self) -> None:
        release_item = threading.Event()

        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            stream_id = opened["params"]["stream_id"]
            ok(connection, opened, {"stream_id": stream_id})
            release_item.wait(1)
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/1",
                    "type": "stream_item",
                    "stream_id": stream_id,
                    "sequence": "1",
                    "item": {"kind": "later"},
                },
            )
            canceled = next(requests)
            ok(connection, canceled, {})

        async def exercise(path):
            async with cmux.aio.Client(path) as client:
                stream = await client.session(SESSION).events()
                with self.assertRaises(cmux.TimeoutError):
                    await stream.next(timeout=0.02)
                self.assertIsNone(stream.end)
                release_item.set()
                item = await stream.next(timeout=1)
                self.assertEqual(item.item.kind, "later")
                await stream.cancel()

        with UnixJsonServer(handler) as server:
            asyncio.run(exercise(server.path))

    def test_aio_request_options_apply_one_call_deadline(self) -> None:
        first_seen = threading.Event()

        def handler(connection, _index):
            requests = frames(connection)
            next(requests)
            first_seen.set()
            ping = next(requests)
            ok(
                connection,
                ping,
                {
                    "alive": True,
                    "cursor": {
                        "generation": "generation-a",
                        "revision": "1",
                    },
                },
            )

        async def exercise(path):
            async with cmux.aio.Client(path, timeout=1) as client:
                with self.assertRaises(cmux.TimeoutError):
                    await client.list_machines(
                        request_options=RequestOptions(timeout=0.02)
                    )
                self.assertTrue(first_seen.is_set())
                self.assertTrue(
                    (await client.session(SESSION).ping()).alive
                )

        with UnixJsonServer(handler) as server:
            asyncio.run(exercise(server.path))

    def test_aio_cancellation_preserves_connection_and_releases_threads(self) -> None:
        request_seen = threading.Event()

        def handler(connection, _index):
            requests = frames(connection)
            next(requests)
            request_seen.set()
            ping = next(requests)
            ok(
                connection,
                ping,
                {
                    "alive": True,
                    "cursor": {
                        "generation": "generation-a",
                        "revision": "1",
                    },
                },
            )

        async def exercise(path):
            client = cmux.aio.Client(path)
            task = asyncio.create_task(client.list_machines())
            await asyncio.to_thread(request_seen.wait, 1)
            task.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await task
            self.assertFalse(client.closed)
            result = await client.session(SESSION).ping()
            self.assertTrue(result.alive)
            await client.close()

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
