from __future__ import annotations

import asyncio
import json
import threading
import time
import unittest
from unittest.mock import patch

import cmux
import cmux._protocol as resource_protocol
import cmux.aio
import cmux.raw
from cmux import (
    AgentId,
    BrowserId,
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
    AgentReportOptions,
    BrowserMouseOptions,
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
BROWSER = BrowserId(f"browser_{HEX_B}")
MACHINE = MachineId(f"machine_{HEX_A}")
SCREEN = ScreenId(f"screen_{HEX_C}")
PANE = PaneId(f"pane_{HEX_A}")
TAB = TabId(f"tab_{HEX_B}")
PROJECTED_TAB = TabId(f"tab_{HEX_C}")
CONNECTED_CLIENT = ConnectedClientId(f"client_{HEX_C}")
PAIRING_REQUEST = PairingRequestId(f"pairing_{HEX_A}")
AGENT = AgentId(f"agent_{HEX_B}")


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
            "protocol": "cmux.protocol/2",
            "type": "response",
            "id": request["id"],
            "ok": True,
            "result": result,
        },
    )


def canceled_end(connection, stream_id, **fields):
    send_frame(
        connection,
        {
            "protocol": "cmux.protocol/2",
            "type": "stream_end",
            "stream_id": stream_id,
            "reason": "canceled",
            **fields,
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
        self.assertTrue(hasattr(cmux.Session, "report_agent"))
        self.assertFalse(hasattr(cmux.Agent, "report"))

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

    def test_terminal_project_preserves_one_runtime_and_encodes_the_new_view(self) -> None:
        observed = []

        def handler(connection, _index):
            request = next(frames(connection))
            observed.append(request)
            ok(
                connection,
                request,
                {
                    "value": {
                        "id": str(PROJECTED_TAB),
                        "pane_id": str(PANE),
                        "name": "mirror",
                        "index": 2,
                        "focused": False,
                        "content_kind": "terminal",
                        "content_id": str(TERMINAL),
                    },
                    "generation": "generation-a",
                    "revision": "7",
                    "replayed": False,
                },
            )

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                projected = client.session(SESSION).terminal(TERMINAL).project(
                    destination_workspace=WORKSPACE,
                    destination_screen=SCREEN,
                    destination_pane=PANE,
                    index=2,
                    name="mirror",
                    idempotency_key="project-terminal",
                )

        self.assertEqual(projected.value.snapshot.id, PROJECTED_TAB)
        self.assertEqual(projected.value.snapshot.content_id, TERMINAL)
        self.assertEqual(observed[0]["operation"], "terminal.project")
        self.assertEqual(
            observed[0]["params"],
            {
                "machine": "current",
                "session": str(SESSION),
                "terminal": str(TERMINAL),
                "destination_workspace": str(WORKSPACE),
                "destination_screen": str(SCREEN),
                "destination_pane": str(PANE),
                "index": 2,
                "name": "mirror",
            },
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
                        "protocol": "cmux.protocol/2",
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
                        ),
                        expected_revision="7",
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
                            viewport_width=0.5,
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
        self.assertEqual(observed[0]["params"]["expected_revision"], "7")
        self.assertEqual(observed[5]["params"]["viewport_width"], 0.5)

    def test_structured_error_and_stream_cancel_are_connection_local(self) -> None:
        observed = []

        def handler(connection, _index):
            for request in frames(connection):
                observed.append(request)
                if request["operation"] == "session.ping":
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/2",
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
                            "protocol": "cmux.protocol/2",
                            "type": "stream_item",
                            "stream_id": request["params"]["stream_id"],
                            "sequence": "18446744073709551615",
                            "item": {"kind": "changed", "data": {"ok": True}},
                        },
                    )
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/2",
                            "type": "stream_item",
                            "stream_id": request["params"]["stream_id"],
                            "sequence": "18446744073709551614",
                            "item": {"kind": "buffered"},
                        },
                    )
                elif request["operation"] == "stream.cancel":
                    canceled_end(
                        connection,
                        request["params"]["stream"],
                    )
                    ok(connection, request, {})
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
                elif request["operation"] == "agent.report":
                    ok(
                        connection,
                        request,
                        {
                            "value": {
                                "id": str(AGENT),
                                "session_id": str(SESSION),
                                "terminal_id": str(TERMINAL),
                                "state": "working",
                                "source": "socket",
                                "source_session": "codex-1",
                                "updated_at_ms": "10",
                            },
                            "generation": "generation-a",
                            "revision": "9",
                            "replayed": False,
                        },
                    )
                elif request["operation"] == "screen.layout.undo":
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/2",
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
                            "protocol": "cmux.protocol/2",
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
                reported = session.report_agent(
                    AgentReportOptions(
                        terminal_id=TERMINAL,
                        state="working",
                        source="socket",
                        source_session="codex-1",
                    ),
                    idempotency_key="agent-status",
                    expected_revision="9",
                )
                self.assertEqual(reported.value.id, AGENT)
                self.assertEqual(reported.value.snapshot.state, "working")

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
        self.assertEqual(
            by_operation["agent.report"]["idempotency_key"],
            "agent-status",
        )
        self.assertEqual(
            by_operation["agent.report"]["params"],
            {
                "machine": "current",
                "session": str(SESSION),
                "terminal_id": str(TERMINAL),
                "state": "working",
                "source": "socket",
                "source_session": "codex-1",
                "expected_revision": "9",
            },
        )
        self.assertNotIn("agent", by_operation["agent.report"]["params"])

    def test_browser_pointer_frame_tokens_are_exact_decimal_strings(self) -> None:
        observed = []

        def handler(connection, _index):
            for request in frames(connection):
                observed.append(request)
                ok(
                    connection,
                    request,
                    {
                        "value": {},
                        "generation": "generation-a",
                        "revision": "1",
                        "replayed": False,
                    },
                )

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                browser = client.session(SESSION).browser(BROWSER)
                browser.mouse(
                    BrowserMouseOptions(
                        "down",
                        10.5,
                        20.25,
                        18_446_744_073_709_551_615,
                        button="left",
                        click_count=1,
                    ),
                    idempotency_key="mouse-token",
                )
                browser.wheel(
                    1.5,
                    -2.5,
                    x_px=30.0,
                    y_px=40.0,
                    pointer_frame_seq=7,
                    idempotency_key="wheel-token",
                )

        self.assertEqual(
            observed[0]["params"]["pointer_frame_seq"],
            "18446744073709551615",
        )
        self.assertEqual(observed[1]["params"]["pointer_frame_seq"], "7")
        self.assertEqual(
            [request["operation"] for request in observed],
            ["browser.input.mouse", "browser.input.wheel"],
        )

    def test_browser_pointer_input_rejects_non_uint64_tokens_before_write(
        self,
    ) -> None:
        observed = []

        def handler(connection, _index):
            request = next(frames(connection))
            observed.append(request)
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

        invalid_tokens = (
            None,
            True,
            1.0,
            -1,
            18_446_744_073_709_551_616,
        )
        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                browser = client.session(SESSION).browser(BROWSER)
                for token in invalid_tokens:
                    with self.assertRaises(ValueError):
                        browser.mouse(
                            BrowserMouseOptions(
                                "move",
                                1.0,
                                2.0,
                                token,  # type: ignore[arg-type]
                            ),
                            idempotency_key="invalid-mouse",
                        )
                    with self.assertRaises(ValueError):
                        browser.wheel(
                            1.0,
                            2.0,
                            x_px=3.0,
                            y_px=4.0,
                            pointer_frame_seq=token,  # type: ignore[arg-type]
                            idempotency_key="invalid-wheel",
                        )
                client.session(SESSION).ping()

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.ping"],
        )

    def test_browser_attach_frame_requires_nullable_decimal_pointer_token(
        self,
    ) -> None:
        def read_frame(pointer_frame_seq):
            def handler(connection, _index):
                requests = frames(connection)
                opened = next(requests)
                stream_id = opened["params"]["stream_id"]
                ok(
                    connection,
                    opened,
                    {
                        "stream_id": stream_id,
                        "attachment_lease": "browser-lease",
                    },
                )
                item = {
                    "kind": "frame",
                    "mime_type": "image/png",
                    "data_base64": "AA==",
                    "width_px": 1,
                    "height_px": 1,
                }
                if pointer_frame_seq is not missing:
                    item["pointer_frame_seq"] = pointer_frame_seq
                send_frame(
                    connection,
                    {
                        "protocol": "cmux.protocol/2",
                        "type": "stream_item",
                        "stream_id": stream_id,
                        "sequence": "1",
                        "item": item,
                    },
                )
                for request in requests:
                    ok(connection, request, {})

            with UnixJsonServer(handler) as server:
                with Client(server.path) as client:
                    stream = client.session(SESSION).browser(BROWSER).attach()
                    return next(stream).item

        missing = object()
        maximum = read_frame("18446744073709551615")
        self.assertIsInstance(maximum, cmux.BrowserAttachFrame)
        self.assertEqual(
            maximum.pointer_frame_seq,
            18_446_744_073_709_551_615,
        )
        self.assertIsNone(read_frame(None).pointer_frame_seq)

        for malformed in (
            missing,
            7,
            True,
            "",
            "01",
            "-1",
            "18446744073709551616",
        ):
            with self.assertRaises(cmux.ProtocolError):
                read_frame(malformed)

    def test_indeterminate_mutation_is_typed_and_never_retried(self) -> None:
        observed = []

        def handler(connection, _index):
            for request in frames(connection):
                observed.append(request)
                send_frame(
                    connection,
                    {
                        "protocol": "cmux.protocol/2",
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
                "outcome": "applied",
            },
            "terminal.viewer.release": {"outcome": "applied"},
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
                process = terminal.process()
                self.assertEqual(process.children, (43,))
                # Older servers omit foreground_cwd; decoders treat it as null.
                self.assertIsNone(process.foreground_cwd)
                self.assertEqual(
                    terminal.resize_viewer(
                        "terminal-lease",
                        cmux.ViewerSizeOptions(100, 30),
                    ).size.cols,
                    100,
                )
                self.assertEqual(
                    terminal.release_viewer("terminal-lease").outcome,
                    "applied",
                )
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

    def test_idempotency_keys_match_the_durable_identifier_contract(self) -> None:
        observed = []

        def handler(connection, _index):
            for request in frames(connection):
                observed.append(request)
                send_frame(
                    connection,
                    {
                        "protocol": "cmux.protocol/2",
                        "type": "response",
                        "id": request["id"],
                        "ok": False,
                        "error": {
                            "code": "mutation.indeterminate",
                            "message": "external effect may have completed",
                            "details": {
                                "idempotency_key": request["idempotency_key"],
                                "operation": request["operation"],
                                "recovery": "inspect_state_then_retry_with_new_key",
                            },
                            "retryable": False,
                        },
                    },
                )

        with UnixJsonServer(handler) as server:
            with Client(server.path) as client:
                rename = client.session(SESSION).workspace(WORKSPACE).rename
                for invalid in (
                    "",
                    " \u00a0\u3000",
                    "key\ncontrol",
                    "key\u0085control",
                    "\u00e9" * 65,
                    "\ud800",
                ):
                    with self.subTest(invalid=repr(invalid)):
                        with self.assertRaises(ValueError):
                            rename("renamed", idempotency_key=invalid)
                for valid in (" key ", "\ufeff", "\u00e9" * 64):
                    with self.subTest(valid=repr(valid)):
                        with self.assertRaises(MutationIndeterminateError):
                            rename("renamed", idempotency_key=valid)

        self.assertEqual(
            [request["idempotency_key"] for request in observed],
            [" key ", "\ufeff", "\u00e9" * 64],
        )

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
            "tab_ids": [str(TAB)],
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

    def test_terminal_snapshot_accepts_protocol_one_tab_id_alias(self) -> None:
        responses = [
            {
                "id": str(TERMINAL),
                "tab_id": str(TAB),
                "title": "attached",
                "cols": 80,
                "rows": 24,
                "running": True,
                "lifecycle": "running",
            },
            {
                "id": str(TERMINAL),
                "tab_id": None,
                "title": "detached",
                "cols": 80,
                "rows": 24,
                "running": True,
                "lifecycle": "running",
            },
            {
                "id": str(TERMINAL),
                "tab_id": str(TAB),
                "tab_ids": [str(TAB)],
                "title": "dual",
                "cols": 80,
                "rows": 24,
                "running": True,
                "lifecycle": "running",
            },
        ]
        expected = [(TAB,), (), (TAB,)]
        for response, tab_ids in zip(responses, expected):
            def handler(connection, _index, response=response):
                request = next(frames(connection))
                ok(connection, request, response)

            with UnixJsonServer(handler) as server:
                with Client(server.path) as client:
                    snapshot = client.session(SESSION).terminal(TERMINAL).refresh()
            self.assertEqual(snapshot.tab_ids, tab_ids)

        invalid = dict(responses[0])
        invalid.pop("tab_id")
        with self.assertRaises(cmux.ProtocolError):
            cmux.resources._terminal_snapshot(invalid)
        inconsistent = {**responses[0], "tab_ids": []}
        with self.assertRaises(cmux.ProtocolError):
            cmux.resources._terminal_snapshot(inconsistent)

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

    def test_terminal_wait_timeout_cancels_once_and_gates_reuse(self) -> None:
        observed = []
        wait_seen = threading.Event()
        cancel_seen = threading.Event()
        release_cancel = threading.Event()
        ping_seen = threading.Event()

        def handler(connection, _index):
            requests = frames(connection)
            target = next(requests)
            observed.append(target)
            wait_seen.set()
            canceled = next(requests)
            observed.append(canceled)
            cancel_seen.set()
            release_cancel.wait(1)
            ok(connection, canceled, {"canceled": True})
            ping = next(requests)
            observed.append(ping)
            ping_seen.set()
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
            with Client(server.path, timeout=0.2) as client:
                session = client.session(SESSION)
                terminal = session.terminal(TERMINAL)
                wait_failures = []
                ping_results = []

                def wait():
                    try:
                        client.with_request_options(
                            RequestOptions(timeout=0.02),
                            terminal.wait,
                            cmux.TerminalWaitOptions("never"),
                        )
                    except BaseException as error:
                        wait_failures.append(error)

                def ping():
                    ping_results.append(session.ping())

                wait_thread = threading.Thread(target=wait)
                wait_thread.start()
                self.assertTrue(wait_seen.wait(1))
                self.assertTrue(cancel_seen.wait(1))
                ping_thread = threading.Thread(target=ping)
                ping_thread.start()
                self.assertFalse(ping_seen.wait(0.03))
                release_cancel.set()
                wait_thread.join(timeout=1)
                ping_thread.join(timeout=1)
                self.assertFalse(wait_thread.is_alive())
                self.assertFalse(ping_thread.is_alive())

        self.assertEqual(len(wait_failures), 1)
        self.assertIsInstance(wait_failures[0], cmux.TimeoutError)
        self.assertIn(
            "terminal.wait did not respond before the deadline",
            str(wait_failures[0]),
        )
        self.assertEqual(len(ping_results), 1)
        self.assertTrue(ping_results[0].alive)
        self.assertEqual(
            [request["operation"] for request in observed],
            ["terminal.wait", "request.cancel", "session.ping"],
        )
        self.assertEqual(
            observed[1]["params"],
            {"request_id": observed[0]["id"]},
        )

    def test_terminal_wait_exit_timeout_uses_request_cancel(self) -> None:
        observed = []

        def handler(connection, _index):
            requests = frames(connection)
            target = next(requests)
            observed.append(target)
            canceled = next(requests)
            observed.append(canceled)
            ok(connection, canceled, {"canceled": True})

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.1) as client:
                terminal = client.session(SESSION).terminal(TERMINAL)
                with self.assertRaises(cmux.TimeoutError):
                    client.with_request_options(
                        RequestOptions(timeout=0.01),
                        terminal.wait_exit,
                    )

        self.assertEqual(
            [request["operation"] for request in observed],
            ["terminal.wait_exit", "request.cancel"],
        )
        self.assertEqual(
            observed[1]["params"],
            {"request_id": observed[0]["id"]},
        )

    def test_terminal_wait_cancellation_only_cancels_after_dispatch(self) -> None:
        observed = []

        def before_handler(connection, _index):
            request = next(frames(connection))
            observed.append(request)
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
                session = client.session(SESSION)
                with self.assertRaises(CancelledError) as raised:
                    client.with_request_options(
                        RequestOptions(cancellation=cancellation),
                        session.terminal(TERMINAL).wait,
                        cmux.TerminalWaitOptions("never"),
                    )
                self.assertFalse(raised.exception.dispatched)
                self.assertTrue(session.ping().alive)
        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.ping"],
        )

        observed.clear()
        wait_seen = threading.Event()

        def after_handler(connection, _index):
            requests = frames(connection)
            target = next(requests)
            observed.append(target)
            wait_seen.set()
            canceled = next(requests)
            observed.append(canceled)
            ok(connection, canceled, {"canceled": True})

        cancellation = CancellationToken()
        failures = []
        with UnixJsonServer(after_handler) as server:
            with Client(server.path, timeout=0.2) as client:
                terminal = client.session(SESSION).terminal(TERMINAL)

                def wait():
                    try:
                        client.with_request_options(
                            RequestOptions(cancellation=cancellation),
                            terminal.wait,
                            cmux.TerminalWaitOptions("never"),
                        )
                    except BaseException as error:
                        failures.append(error)

                wait_thread = threading.Thread(target=wait)
                wait_thread.start()
                self.assertTrue(wait_seen.wait(1))
                cancellation.cancel()
                cancellation.cancel()
                wait_thread.join(timeout=1)
                self.assertFalse(wait_thread.is_alive())

        self.assertEqual(len(failures), 1)
        self.assertIsInstance(failures[0], CancelledError)
        self.assertTrue(failures[0].dispatched)
        self.assertEqual(
            [request["operation"] for request in observed],
            ["terminal.wait", "request.cancel"],
        )
        self.assertEqual(
            observed[1]["params"],
            {"request_id": observed[0]["id"]},
        )

    def test_request_cancel_false_drains_raced_wait_before_reuse(self) -> None:
        for response_first in (False, True):
            with self.subTest(response_first=response_first):
                observed = []
                wait_seen = threading.Event()
                cancel_seen = threading.Event()
                first_sent = threading.Event()
                release_second = threading.Event()
                ping_seen = threading.Event()

                def handler(connection, _index):
                    requests = frames(connection)
                    target = next(requests)
                    observed.append(target)
                    wait_seen.set()
                    canceled = next(requests)
                    observed.append(canceled)
                    cancel_seen.set()
                    if response_first:
                        ok(connection, target, {"matched": False, "text": ""})
                    else:
                        ok(connection, canceled, {"canceled": False})
                    first_sent.set()
                    release_second.wait(1)
                    if response_first:
                        ok(connection, canceled, {"canceled": False})
                    else:
                        ok(connection, target, {"matched": False, "text": ""})
                    ping = next(requests)
                    observed.append(ping)
                    ping_seen.set()
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
                    with Client(server.path, timeout=0.2) as client:
                        session = client.session(SESSION)
                        terminal = session.terminal(TERMINAL)
                        cancellation = CancellationToken()
                        failures = []
                        ping_results = []

                        def wait():
                            try:
                                client.with_request_options(
                                    RequestOptions(
                                        cancellation=cancellation,
                                    ),
                                    terminal.wait,
                                    cmux.TerminalWaitOptions("never"),
                                )
                            except BaseException as error:
                                failures.append(error)

                        wait_thread = threading.Thread(target=wait)
                        wait_thread.start()
                        self.assertTrue(wait_seen.wait(1))
                        cancellation.cancel()
                        self.assertTrue(cancel_seen.wait(1))
                        ping_thread = threading.Thread(
                            target=lambda: ping_results.append(session.ping())
                        )
                        ping_thread.start()
                        self.assertTrue(first_sent.wait(1))
                        self.assertFalse(ping_seen.wait(0.03))
                        release_second.set()
                        wait_thread.join(timeout=1)
                        ping_thread.join(timeout=1)
                        self.assertFalse(wait_thread.is_alive())
                        self.assertFalse(ping_thread.is_alive())

                self.assertEqual(len(failures), 1)
                self.assertIsInstance(failures[0], CancelledError)
                self.assertEqual(len(ping_results), 1)
                self.assertTrue(ping_results[0].alive)
                self.assertEqual(
                    [request["operation"] for request in observed],
                    ["terminal.wait", "request.cancel", "session.ping"],
                )

    def test_request_cancel_false_rejects_malformed_result_in_both_orders(
        self,
    ) -> None:
        for response_first in (False, True):
            with self.subTest(response_first=response_first):
                disconnected = threading.Event()

                def handler(connection, _index):
                    try:
                        requests = frames(connection)
                        target = next(requests)
                        canceled = next(requests)
                        if response_first:
                            ok(connection, target, {"matched": True})
                            ok(connection, canceled, {"canceled": False})
                        else:
                            ok(connection, canceled, {"canceled": False})
                            ok(connection, target, {"matched": True})
                        list(requests)
                    finally:
                        disconnected.set()

                with UnixJsonServer(handler) as server:
                    with Client(server.path, timeout=0.05) as client:
                        terminal = client.session(SESSION).terminal(TERMINAL)
                        with self.assertRaises(cmux.TimeoutError):
                            client.with_request_options(
                                RequestOptions(timeout=0.01),
                                terminal.wait,
                                cmux.TerminalWaitOptions("never"),
                            )
                        self.assertTrue(client.closed)
                        with self.assertRaises(
                            (CmuxConnectionError, cmux.ProtocolError)
                        ):
                            client.session(SESSION).ping()
                        self.assertTrue(disconnected.wait(0.5))

    def test_unconfirmed_terminal_wait_cancel_closes_without_masking_timeout(
        self,
    ) -> None:
        for failure in (
            "malformed-cancel",
            "malformed-target",
            "missing-target",
            "true-after-target",
        ):
            with self.subTest(failure=failure):
                observed = []
                disconnected = threading.Event()

                def handler(connection, _index):
                    try:
                        requests = frames(connection)
                        target = next(requests)
                        observed.append(target)
                        canceled = next(requests)
                        observed.append(canceled)
                        if failure == "malformed-cancel":
                            ok(
                                connection,
                                canceled,
                                {"canceled": True, "extra": True},
                            )
                        elif failure == "true-after-target":
                            ok(
                                connection,
                                target,
                                {"matched": False, "text": ""},
                            )
                            ok(connection, canceled, {"canceled": True})
                        else:
                            ok(connection, canceled, {"canceled": False})
                            if failure == "malformed-target":
                                send_frame(
                                    connection,
                                    {
                                        "protocol": "cmux.protocol/2",
                                        "type": "response",
                                        "id": target["id"],
                                        "ok": True,
                                        "result": {
                                            "matched": False,
                                            "text": "",
                                        },
                                        "extra": True,
                                    },
                                )
                        list(requests)
                    finally:
                        disconnected.set()

                with UnixJsonServer(handler) as server:
                    with Client(server.path, timeout=0.05) as client:
                        terminal = client.session(SESSION).terminal(TERMINAL)
                        with self.assertRaises(cmux.TimeoutError) as raised:
                            client.with_request_options(
                                RequestOptions(timeout=0.01),
                                terminal.wait,
                                cmux.TerminalWaitOptions("never"),
                            )
                        self.assertIn(
                            "terminal.wait did not respond before the deadline",
                            str(raised.exception),
                        )
                        self.assertTrue(client.closed)
                        with self.assertRaises(
                            (CmuxConnectionError, cmux.ProtocolError)
                        ):
                            client.session(SESSION).ping()
                        self.assertTrue(disconnected.wait(0.5))
                self.assertEqual(
                    [request["operation"] for request in observed],
                    ["terminal.wait", "request.cancel"],
                )

    def test_uncertain_request_cancel_send_closes_without_masking_timeout(
        self,
    ) -> None:
        wait_seen = threading.Event()
        disconnected = threading.Event()

        def handler(connection, _index):
            try:
                request = next(frames(connection))
                self.assertEqual(request["operation"], "terminal.wait")
                wait_seen.set()
                connection.recv(1)
            finally:
                disconnected.set()

        attempted = []
        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.05) as client:
                def uncertain_send(value, timeout):
                    attempted.append(value)
                    raise CmuxConnectionError("uncertain cancel send")

                with patch.object(
                    client._connection._wire,
                    "send_bounded",
                    side_effect=uncertain_send,
                ):
                    with self.assertRaises(cmux.TimeoutError) as raised:
                        client.with_request_options(
                            RequestOptions(timeout=0.01),
                            client.session(SESSION).terminal(TERMINAL).wait,
                            cmux.TerminalWaitOptions("never"),
                        )
                self.assertTrue(wait_seen.is_set())
                self.assertIn(
                    "terminal.wait did not respond before the deadline",
                    str(raised.exception),
                )
                self.assertTrue(client.closed)
                self.assertTrue(disconnected.wait(0.5))

        self.assertEqual(len(attempted), 1)
        self.assertEqual(attempted[0]["operation"], "request.cancel")
        self.assertEqual(
            set(attempted[0]["params"]),
            {"request_id"},
        )

    def test_acknowledged_stream_outlives_the_request_timeout(self) -> None:
        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            stream_id = opened["params"]["stream_id"]
            ok(connection, opened, {"stream_id": stream_id})

            time.sleep(0.15)
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/2",
                    "type": "stream_item",
                    "stream_id": stream_id,
                    "sequence": "1",
                    "item": {"kind": "delayed"},
                },
            )

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
            canceled = next(requests)
            ok(connection, canceled, {})
            canceled_end(connection, stream_id)

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.05) as client:
                session = client.session(SESSION)
                stream = session.events()
                item = stream.next(timeout=1)
                self.assertEqual(item.item.kind, "delayed")
                self.assertTrue(session.ping().alive)
                stream.cancel()

    def test_stream_open_timeout_cancels_remote_route_and_recovers(self) -> None:
        observed = []

        def handler(connection, _index):
            requests = frames(connection)
            first_open = next(requests)
            observed.append(first_open)
            first_stream_id = first_open["params"]["stream_id"]

            first_cancel = next(requests)
            observed.append(first_cancel)
            ok(connection, first_open, {"stream_id": first_stream_id})
            ok(connection, first_cancel, {})

            second_open = next(requests)
            observed.append(second_open)
            second_stream_id = second_open["params"]["stream_id"]
            ok(connection, second_open, {"stream_id": second_stream_id})

            second_cancel = next(requests)
            observed.append(second_cancel)
            canceled_end(connection, second_stream_id)
            ok(connection, second_cancel, {})

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                session = client.session(SESSION)
                with self.assertRaises(cmux.TimeoutError) as raised:
                    client.with_request_options(
                        RequestOptions(timeout=0.02),
                        session.events,
                    )
                self.assertIn(
                    "session.events did not respond before the deadline",
                    str(raised.exception),
                )
                self.assertEqual(client._connection._streams, {})

                stream = session.events()
                stream.cancel()
                self.assertEqual(client._connection._streams, {})

        first_open, first_cancel, second_open, second_cancel = observed
        self.assertEqual(first_open["operation"], "session.events")
        self.assertEqual(first_cancel["operation"], "stream.cancel")
        self.assertEqual(
            first_cancel["params"]["stream"],
            first_open["params"]["stream_id"],
        )
        self.assertNotEqual(
            first_open["params"]["stream_id"],
            second_open["params"]["stream_id"],
        )
        self.assertEqual(second_cancel["operation"], "stream.cancel")

    def test_failed_stream_open_ack_cancels_without_masking_error(self) -> None:
        other_stream_id = f"stream_{HEX_B}"
        cases = (
            (
                "mismatched",
                lambda stream_id: {"stream_id": other_stream_id},
                "returned a different stream_id",
            ),
            (
                "malformed",
                lambda stream_id: {
                    "stream_id": stream_id,
                    "unexpected": True,
                },
                "contains unknown field 'unexpected'",
            ),
        )

        for label, response, expected in cases:
            with self.subTest(case=label):
                observed = []

                def handler(connection, _index):
                    requests = frames(connection)
                    opened = next(requests)
                    observed.append(opened)
                    ok(
                        connection,
                        opened,
                        response(opened["params"]["stream_id"]),
                    )
                    canceled = next(requests)
                    observed.append(canceled)
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/2",
                            "type": "response",
                            "id": canceled["id"],
                            "ok": False,
                            "error": {
                                "code": "operation.failed",
                                "message": "cancel fixture failed",
                                "details": {"reason": "fixture"},
                                "retryable": False,
                            },
                        },
                    )

                with UnixJsonServer(handler) as server:
                    with Client(server.path, timeout=0.2) as client:
                        with self.assertRaises(cmux.ProtocolError) as raised:
                            client.session(SESSION).events()
                        self.assertIn(expected, str(raised.exception))
                        self.assertEqual(client._connection._streams, {})

                self.assertEqual(
                    [request["operation"] for request in observed],
                    ["session.events", "stream.cancel"],
                )
                self.assertEqual(
                    observed[1]["params"]["stream"],
                    observed[0]["params"]["stream_id"],
                )

    def test_failed_stream_open_cleanup_failure_closes_connection(self) -> None:
        for failure_mode in ("send", "response_timeout"):
            with self.subTest(failure_mode=failure_mode):
                observed = []
                disconnected = threading.Event()
                original_error = cmux.ProtocolError(
                    f"original {failure_mode} stream-open failure"
                )
                cleanup_send_error = CmuxConnectionError(
                    "synthetic stream.cancel send failure"
                )
                cleanup_send_attempts = []

                def handler(connection, _index):
                    requests = frames(connection)
                    opened = next(requests)
                    observed.append(opened)
                    ok(
                        connection,
                        opened,
                        {"stream_id": opened["params"]["stream_id"]},
                    )
                    for request in requests:
                        observed.append(request)
                    disconnected.set()

                with UnixJsonServer(handler) as server:
                    with Client(server.path, timeout=0.02) as client:
                        session = client.session(SESSION)

                        def fail_bounded_send(value, _timeout, _guard):
                            cleanup_send_attempts.append(value)
                            raise cleanup_send_error

                        started = time.monotonic()
                        with patch.object(
                            resource_protocol,
                            "_validate_stream_open_result",
                            side_effect=original_error,
                        ):
                            if failure_mode == "send":
                                with patch.object(
                                    client._connection._wire,
                                    "send_bounded_if",
                                    side_effect=fail_bounded_send,
                                ):
                                    with self.assertRaises(
                                        cmux.ProtocolError
                                    ) as raised:
                                        session.events()
                            else:
                                with self.assertRaises(
                                    cmux.ProtocolError
                                ) as raised:
                                    session.events()
                        self.assertIs(raised.exception, original_error)
                        self.assertLess(time.monotonic() - started, 0.5)
                        self.assertTrue(client.closed)
                        self.assertTrue(client._connection._wire.closed)
                        self.assertTrue(disconnected.wait(0.5))

                        retry_started = time.monotonic()
                        with self.assertRaises(CmuxConnectionError) as retry:
                            session.ping()
                        self.assertLess(time.monotonic() - retry_started, 0.1)
                        self.assertIn(
                            "failed-open cleanup was not confirmed",
                            str(retry.exception),
                        )

                expected_operations = (
                    ["session.events"]
                    if failure_mode == "send"
                    else ["session.events", "stream.cancel"]
                )
                self.assertEqual(
                    [request["operation"] for request in observed],
                    expected_operations,
                )
                if failure_mode == "send":
                    self.assertEqual(
                        [
                            request["operation"]
                            for request in cleanup_send_attempts
                        ],
                        ["stream.cancel"],
                    )

    def test_stream_open_cancellation_only_cancels_after_dispatch(self) -> None:
        opened = threading.Event()
        observed = []

        def handler(connection, _index):
            requests = frames(connection)
            request = next(requests)
            observed.append(request)
            opened.set()
            canceled = next(requests)
            observed.append(canceled)
            ok(connection, canceled, {})

        cancellation = CancellationToken()

        def cancel_after_open():
            opened.wait(1)
            cancellation.cancel()

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                cancel_thread = threading.Thread(target=cancel_after_open)
                cancel_thread.start()
                with self.assertRaises(CancelledError) as raised:
                    client.with_request_options(
                        RequestOptions(cancellation=cancellation),
                        client.session(SESSION).events,
                    )
                cancel_thread.join(timeout=1)
                self.assertFalse(cancel_thread.is_alive())
                self.assertTrue(opened.is_set())
                self.assertTrue(raised.exception.dispatched)
                self.assertEqual(client._connection._streams, {})

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )
        self.assertEqual(
            observed[1]["params"]["stream"],
            observed[0]["params"]["stream_id"],
        )

        observed.clear()
        cancellation = CancellationToken()
        cancellation.cancel()

        def before_handler(connection, _index):
            request = next(frames(connection))
            observed.append(request)
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

        with UnixJsonServer(before_handler) as server:
            with Client(server.path) as client:
                with self.assertRaises(CancelledError) as raised:
                    client.with_request_options(
                        RequestOptions(cancellation=cancellation),
                        client.session(SESSION).events,
                    )
                self.assertFalse(raised.exception.dispatched)
                self.assertEqual(client._connection._streams, {})
                self.assertTrue(client.session(SESSION).ping().alive)

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.ping"],
        )

    def test_stream_open_transport_failures_clean_routes_without_false_cancel(
        self,
    ) -> None:
        observed = []
        cleanup_seen = threading.Event()

        def reader_failure_handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            observed.append(opened)
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/future",
                    "type": "response",
                    "id": opened["id"],
                    "ok": True,
                    "result": {
                        "stream_id": opened["params"]["stream_id"],
                    },
                },
            )
            canceled = next(requests)
            observed.append(canceled)
            cleanup_seen.set()

        with UnixJsonServer(reader_failure_handler) as server:
            with Client(server.path, timeout=0.2) as client:
                with self.assertRaises(cmux.ProtocolError) as raised:
                    client.session(SESSION).events()
                self.assertIn("wrong protocol", str(raised.exception))
                self.assertTrue(cleanup_seen.wait(1))
                self.assertEqual(client._connection._streams, {})

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )
        self.assertEqual(
            observed[1]["params"]["stream"],
            observed[0]["params"]["stream_id"],
        )

        def handler(connection, _index):
            next(frames(connection))

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                attempted = []
                send_bounded = client._connection._wire.send_bounded_if

                def track_bounded(value, timeout, should_send):
                    def track_guard():
                        result = should_send()
                        attempted.append((value, result))
                        return result

                    return send_bounded(value, timeout, track_guard)

                client._connection._wire.send_bounded_if = track_bounded
                with self.assertRaises(CmuxConnectionError) as raised:
                    client.session(SESSION).events()
                self.assertIn("closed", str(raised.exception))
                deadline = time.monotonic() + 1
                while not attempted and time.monotonic() < deadline:
                    time.sleep(0.001)
                self.assertEqual(
                    sum(1 for _value, guard in attempted if guard),
                    1,
                )
                self.assertTrue(
                    all(
                        value["operation"] == "stream.cancel"
                        for value, _guard in attempted
                    )
                )
                self.assertEqual(client._connection._streams, {})

        def idle_handler(connection, _index):
            while connection.recv(1):
                pass

        with UnixJsonServer(idle_handler) as server:
            with Client(server.path) as client:
                cleanup_guards = []
                expected = CmuxConnectionError("synthetic send failure")
                send_bounded = client._connection._wire.send_bounded_if

                def track_bounded(value, timeout, should_send):
                    def track_guard():
                        result = should_send()
                        cleanup_guards.append(result)
                        return result

                    return send_bounded(value, timeout, track_guard)

                client._connection._wire.send_bounded_if = track_bounded
                with patch.object(
                    client._connection._wire,
                    "send",
                    side_effect=expected,
                ):
                    with self.assertRaises(CmuxConnectionError) as raised:
                        client.session(SESSION).events()
                self.assertIs(raised.exception, expected)
                self.assertEqual(cleanup_guards, [])
                self.assertEqual(client._connection._streams, {})

    def test_stream_open_send_error_after_delivery_closes_without_cancel(
        self,
    ) -> None:
        observed = []
        open_seen = threading.Event()
        disconnected = threading.Event()

        def handler(connection, _index):
            try:
                for request in frames(connection):
                    observed.append(request)
                    open_seen.set()
                    ok(
                        connection,
                        request,
                        {"stream_id": request["params"]["stream_id"]},
                    )
            finally:
                disconnected.set()

        expected = CmuxConnectionError(
            "synthetic failure after the complete frame was delivered"
        )
        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                session = client.session(SESSION)
                send_encoded = client._connection._wire._send_encoded

                def deliver_then_fail(encoded):
                    send_encoded(encoded)
                    if not open_seen.wait(1):
                        raise AssertionError("server did not receive stream open")
                    raise expected

                with patch.object(
                    client._connection._wire,
                    "_send_encoded",
                    side_effect=deliver_then_fail,
                ):
                    with self.assertRaises(CmuxConnectionError) as raised:
                        session.events()
                self.assertIs(raised.exception, expected)
                self.assertTrue(client.closed)
                self.assertTrue(client._connection._wire.closed)
                self.assertTrue(disconnected.wait(0.5))

                started = time.monotonic()
                with self.assertRaises(CmuxConnectionError):
                    session.ping()
                self.assertLess(time.monotonic() - started, 0.1)

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events"],
        )

    def test_conclusive_stream_open_rejection_keeps_connection_reusable(
        self,
    ) -> None:
        observed = []

        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            observed.append(opened)
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/2",
                    "type": "response",
                    "id": opened["id"],
                    "ok": False,
                    "error": {
                        "code": "selector.not_found",
                        "message": "session is gone",
                        "details": {"selector": str(SESSION)},
                        "retryable": False,
                    },
                },
            )

            ping = next(requests)
            observed.append(ping)
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
            with Client(server.path, timeout=0.2) as client:
                session = client.session(SESSION)
                with self.assertRaises(ResourceError) as raised:
                    session.events()
                self.assertEqual(raised.exception.code, "selector.not_found")
                self.assertFalse(raised.exception.retryable)
                self.assertFalse(client.closed)
                self.assertEqual(client._connection._streams, {})
                self.assertTrue(session.ping().alive)

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "session.ping"],
        )

    def test_stream_open_cannot_return_after_acknowledged_protocol_failure(
        self,
    ) -> None:
        observed = []
        failure_sent = threading.Event()
        disconnected = threading.Event()

        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            observed.append(opened)
            ok(
                connection,
                opened,
                {"stream_id": opened["params"]["stream_id"]},
            )
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/future",
                    "type": "stream_item",
                    "stream_id": opened["params"]["stream_id"],
                    "sequence": "1",
                    "item": {"kind": "future.event"},
                },
            )
            failure_sent.set()
            for request in requests:
                observed.append(request)
            disconnected.set()

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                send_encoded = client._connection._wire._send_encoded

                def wait_for_reader_failure(encoded):
                    send_encoded(encoded)
                    if not failure_sent.wait(1):
                        raise AssertionError("server did not send protocol failure")
                    deadline = time.monotonic() + 1
                    while not client.closed and time.monotonic() < deadline:
                        time.sleep(0.001)
                    if not client.closed:
                        raise AssertionError("reader did not fail the connection")

                with patch.object(
                    client._connection._wire,
                    "_send_encoded",
                    side_effect=wait_for_reader_failure,
                ):
                    with self.assertRaises(cmux.ProtocolError) as raised:
                        client.session(SESSION).events()
                self.assertIn("wrong protocol", str(raised.exception))
                self.assertTrue(client.closed)
                self.assertTrue(disconnected.wait(0.5))
                self.assertTrue(client._connection._wire.closed)
                self.assertEqual(client._connection._streams, {})

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )
        self.assertEqual(
            observed[1]["params"]["stream"],
            observed[0]["params"]["stream_id"],
        )

    def test_public_stream_cancel_failure_closes_connection_once(self) -> None:
        observed = []
        disconnected = threading.Event()

        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            observed.append(opened)
            ok(
                connection,
                opened,
                {"stream_id": opened["params"]["stream_id"]},
            )

            canceled = next(requests)
            observed.append(canceled)
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/2",
                    "type": "response",
                    "id": canceled["id"],
                    "ok": False,
                    "error": {
                        "code": "operation.failed",
                        "message": "cancel fixture failed",
                        "details": {"reason": "fixture"},
                        "retryable": False,
                    },
                },
            )
            for request in requests:
                observed.append(request)
            disconnected.set()

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                stream = client.session(SESSION).events()
                with self.assertRaises(ResourceError) as raised:
                    stream.cancel()
                self.assertEqual(raised.exception.code, "operation.failed")
                with self.assertRaises(ResourceError) as repeated:
                    stream.cancel()
                self.assertIs(repeated.exception, raised.exception)
                self.assertTrue(client.closed)
                self.assertTrue(client._connection._wire.closed)
                self.assertTrue(disconnected.wait(0.5))

                started = time.monotonic()
                with self.assertRaises(CmuxConnectionError):
                    client.session(SESSION).ping()
                self.assertLess(time.monotonic() - started, 0.1)

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )

    def test_explicit_cancel_accepts_response_and_end_in_either_order(
        self,
    ) -> None:
        for end_first in (False, True):
            with self.subTest(end_first=end_first):
                observed = []

                def handler(connection, _index):
                    requests = frames(connection)
                    opened = next(requests)
                    observed.append(opened)
                    stream_id = opened["params"]["stream_id"]
                    ok(connection, opened, {"stream_id": stream_id})

                    canceled = next(requests)
                    observed.append(canceled)
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/2",
                            "type": "stream_item",
                            "stream_id": stream_id,
                            "sequence": "1",
                            "item": {"kind": "future.event", "stale": 1},
                        },
                    )

                    def send_end():
                        canceled_end(
                            connection,
                            stream_id,
                            cursor={
                                "generation": "cancel-generation",
                                "revision": "3",
                            },
                            recovery="released",
                        )

                    if end_first:
                        send_end()
                    else:
                        ok(connection, canceled, {})
                    time.sleep(0.02)
                    if end_first:
                        ok(connection, canceled, {})
                    else:
                        send_frame(
                            connection,
                            {
                                "protocol": "cmux.protocol/2",
                                "type": "stream_item",
                                "stream_id": stream_id,
                                "sequence": "2",
                                "cursor": {
                                    "generation": "cancel-generation",
                                    "revision": "2",
                                },
                                "item": {
                                    "kind": "future.event",
                                    "stale": 2,
                                },
                            },
                        )
                        send_end()

                    ping = next(requests)
                    observed.append(ping)
                    ok(
                        connection,
                        ping,
                        {
                            "alive": True,
                            "cursor": {
                                "generation": "cancel-generation",
                                "revision": "4",
                            },
                        },
                    )
                    observed.extend(requests)

                with UnixJsonServer(handler) as server:
                    with Client(server.path, timeout=0.2) as client:
                        session = client.session(SESSION)
                        stream = session.events()
                        started = time.monotonic()
                        stream.cancel()
                        self.assertGreaterEqual(
                            time.monotonic() - started,
                            0.015,
                        )
                        self.assertIsNotNone(stream.end)
                        assert stream.end is not None
                        self.assertEqual(stream.end.reason, "canceled")
                        self.assertEqual(
                            stream.end.cursor,
                            cmux.Cursor("cancel-generation", "3"),
                        )
                        self.assertEqual(stream.end.recovery, "released")
                        with self.assertRaises(StopIteration):
                            next(stream)
                        stream.cancel()
                        self.assertTrue(session.ping().alive)

                self.assertEqual(
                    [request["operation"] for request in observed],
                    ["session.events", "stream.cancel", "session.ping"],
                )

    def test_second_cancel_after_end_waits_for_shared_response(self) -> None:
        observed = []
        end_sent = threading.Event()
        release_response = threading.Event()

        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            observed.append(opened)
            stream_id = opened["params"]["stream_id"]
            ok(connection, opened, {"stream_id": stream_id})
            canceled = next(requests)
            observed.append(canceled)
            canceled_end(connection, stream_id)
            end_sent.set()
            release_response.wait(1)
            ok(connection, canceled, {})
            ping = next(requests)
            observed.append(ping)
            ok(
                connection,
                ping,
                {
                    "alive": True,
                    "cursor": {
                        "generation": "generation-a",
                        "revision": "2",
                    },
                },
            )
            observed.extend(requests)

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                session = client.session(SESSION)
                stream = session.events()
                failures = []
                first_done = threading.Event()
                second_started = threading.Event()
                second_done = threading.Event()

                def first_cancel():
                    try:
                        stream.cancel()
                    except BaseException as error:
                        failures.append(error)
                    finally:
                        first_done.set()

                def second_cancel():
                    second_started.set()
                    try:
                        stream.cancel()
                    except BaseException as error:
                        failures.append(error)
                    finally:
                        second_done.set()

                first = threading.Thread(target=first_cancel)
                first.start()
                self.assertTrue(end_sent.wait(1))
                second = threading.Thread(target=second_cancel)
                second.start()
                self.assertTrue(second_started.wait(1))
                self.assertFalse(second_done.wait(0.02))
                release_response.set()
                self.assertTrue(first_done.wait(1))
                self.assertTrue(second_done.wait(1))
                first.join(timeout=1)
                second.join(timeout=1)
                self.assertEqual(failures, [])
                self.assertTrue(session.ping().alive)

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel", "session.ping"],
        )

    def test_explicit_cancel_rejects_noncanonical_end_and_caches_failure(
        self,
    ) -> None:
        exact_error = {
            "code": "operation.failed",
            "message": "stream failed",
            "details": {"reason": "fixture"},
            "retryable": False,
        }
        cases = (
            ("wrong-reason", {"reason": "completed"}),
            ("wrong-id", {"stream_id": f"stream_{HEX_B}"}),
            ("extra", {"unexpected": True}),
            ("null-cursor", {"cursor": None}),
            (
                "malformed-cursor",
                {"cursor": {"generation": "generation-a"}},
            ),
            ("null-recovery", {"recovery": None}),
            ("non-string-recovery", {"recovery": 7}),
            ("null-error", {"reason": "error", "error": None}),
            (
                "malformed-error",
                {
                    "reason": "error",
                    "error": {**exact_error, "unexpected": True},
                },
            ),
            ("missing-error", {"reason": "error"}),
            (
                "unexpected-error",
                {"reason": "canceled", "error": exact_error},
            ),
        )

        for label, replacement in cases:
            with self.subTest(case=label):
                observed = []
                disconnected = threading.Event()

                def handler(connection, _index):
                    try:
                        requests = frames(connection)
                        opened = next(requests)
                        observed.append(opened)
                        stream_id = opened["params"]["stream_id"]
                        ok(connection, opened, {"stream_id": stream_id})
                        canceled = next(requests)
                        observed.append(canceled)
                        end = {
                            "protocol": "cmux.protocol/2",
                            "type": "stream_end",
                            "stream_id": stream_id,
                            "reason": "canceled",
                        }
                        end.update(replacement)
                        send_frame(connection, end)
                        ok(connection, canceled, {})
                        observed.extend(requests)
                    finally:
                        disconnected.set()

                with UnixJsonServer(handler) as server:
                    with Client(server.path, timeout=0.2) as client:
                        stream = client.session(SESSION).events()
                        with self.assertRaises(cmux.ProtocolError) as raised:
                            stream.cancel()
                        with self.assertRaises(cmux.ProtocolError) as repeated:
                            stream.cancel()
                        self.assertIs(repeated.exception, raised.exception)
                        self.assertTrue(client.closed)
                        self.assertTrue(client._connection._wire.closed)
                        self.assertTrue(disconnected.wait(0.5))

                self.assertEqual(
                    [request["operation"] for request in observed],
                    ["session.events", "stream.cancel"],
                )

    def test_explicit_cancel_rejects_noncanonical_response_and_caches_failure(
        self,
    ) -> None:
        exact_error = {
            "code": "operation.failed",
            "message": "cancel failed",
            "details": {"reason": "fixture"},
            "retryable": False,
        }

        def with_id(request, fields):
            return {
                "protocol": "cmux.protocol/2",
                "type": "response",
                "id": request["id"],
                **fields,
            }

        cases = (
            (
                "nonempty-result",
                lambda request: with_id(
                    request,
                    {"ok": True, "result": {"unexpected": True}},
                ),
            ),
            (
                "extra",
                lambda request: with_id(
                    request,
                    {"ok": True, "result": {}, "unexpected": True},
                ),
            ),
            (
                "success-both",
                lambda request: with_id(
                    request,
                    {"ok": True, "result": {}, "error": exact_error},
                ),
            ),
            (
                "success-missing-result",
                lambda request: with_id(request, {"ok": True}),
            ),
            (
                "non-boolean-ok",
                lambda request: with_id(
                    request,
                    {"ok": "true", "result": {}},
                ),
            ),
            (
                "malformed-error",
                lambda request: with_id(
                    request,
                    {
                        "ok": False,
                        "error": {**exact_error, "unexpected": True},
                    },
                ),
            ),
            (
                "failure-both",
                lambda request: with_id(
                    request,
                    {"ok": False, "result": {}, "error": exact_error},
                ),
            ),
        )

        for label, response in cases:
            with self.subTest(case=label):
                observed = []
                disconnected = threading.Event()

                def handler(connection, _index):
                    try:
                        requests = frames(connection)
                        opened = next(requests)
                        observed.append(opened)
                        stream_id = opened["params"]["stream_id"]
                        ok(connection, opened, {"stream_id": stream_id})
                        canceled = next(requests)
                        observed.append(canceled)
                        canceled_end(connection, stream_id)
                        send_frame(connection, response(canceled))
                        observed.extend(requests)
                    finally:
                        disconnected.set()

                with UnixJsonServer(handler) as server:
                    with Client(server.path, timeout=0.2) as client:
                        stream = client.session(SESSION).events()
                        with self.assertRaises(cmux.ProtocolError) as raised:
                            stream.cancel()
                        with self.assertRaises(cmux.ProtocolError) as repeated:
                            stream.cancel()
                        self.assertIs(repeated.exception, raised.exception)
                        self.assertTrue(client.closed)
                        self.assertTrue(client._connection._wire.closed)
                        self.assertTrue(disconnected.wait(0.5))

                self.assertEqual(
                    [request["operation"] for request in observed],
                    ["session.events", "stream.cancel"],
                )

    def test_stream_items_require_exact_envelopes_and_non_null_cursor(
        self,
    ) -> None:
        cases = (
            ("extra", {"unexpected": True}),
            ("null-cursor", {"cursor": None}),
            ("missing-item", {"item": None}),
            (
                "malformed-cursor",
                {"cursor": {"generation": "generation-a"}},
            ),
            ("noncanonical-sequence", {"sequence": "01"}),
        )

        for label, replacement in cases:
            with self.subTest(case=label):
                release_item = threading.Event()
                disconnected = threading.Event()

                def handler(connection, _index):
                    try:
                        requests = frames(connection)
                        opened = next(requests)
                        stream_id = opened["params"]["stream_id"]
                        ok(connection, opened, {"stream_id": stream_id})
                        release_item.wait(1)
                        item = {
                            "protocol": "cmux.protocol/2",
                            "type": "stream_item",
                            "stream_id": stream_id,
                            "sequence": "1",
                            "item": {"kind": "future.event"},
                        }
                        item.update(replacement)
                        if label == "missing-item":
                            item.pop("item")
                        send_frame(connection, item)
                        list(requests)
                    finally:
                        disconnected.set()

                with UnixJsonServer(handler) as server:
                    with Client(server.path, timeout=0.2) as client:
                        stream = client.session(SESSION).events()
                        release_item.set()
                        with self.assertRaises(cmux.ProtocolError):
                            stream.next(timeout=1)
                        self.assertTrue(client.closed)
                        self.assertTrue(client._connection._wire.closed)
                        self.assertTrue(disconnected.wait(0.5))

    def test_explicit_cancel_validates_known_items_before_discarding_them(
        self,
    ) -> None:
        observed = []
        disconnected = threading.Event()

        def handler(connection, _index):
            try:
                requests = frames(connection)
                opened = next(requests)
                observed.append(opened)
                stream_id = opened["params"]["stream_id"]
                ok(connection, opened, {"stream_id": stream_id})
                canceled = next(requests)
                observed.append(canceled)
                send_frame(
                    connection,
                    {
                        "protocol": "cmux.protocol/2",
                        "type": "stream_item",
                        "stream_id": stream_id,
                        "sequence": "1",
                        "item": {"kind": "snapshot"},
                    },
                )
                ok(connection, canceled, {})
                canceled_end(connection, stream_id)
                observed.extend(requests)
            finally:
                disconnected.set()

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                stream = client.session(SESSION).events()
                with self.assertRaises(cmux.ProtocolError) as raised:
                    stream.cancel()
                self.assertIsNotNone(stream.end)
                assert stream.end is not None
                self.assertIsInstance(stream.end.error, cmux.ProtocolError)
                self.assertIn("invalid stream item", str(stream.end.error))
                with self.assertRaises(cmux.ProtocolError) as repeated:
                    stream.cancel()
                self.assertIs(repeated.exception, raised.exception)
                self.assertTrue(client.closed)
                self.assertTrue(client._connection._wire.closed)
                self.assertTrue(disconnected.wait(0.5))

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )

    def test_journal_record_sequence_must_match_envelope_cursor(self) -> None:
        release_connection = threading.Event()

        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            stream_id = opened["params"]["stream_id"]
            ok(connection, opened, {"stream_id": stream_id})
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/2",
                    "type": "stream_item",
                    "stream_id": stream_id,
                    "sequence": "1",
                    "cursor": {"generation": SESSION, "revision": "1"},
                    "item": {
                        "sequence": "2",
                        "event_id": "event_mismatched_cursor",
                        "schema_version": 1,
                        "kind": "agent.turn.completed",
                        "class": "observation",
                        "replay": "advisory",
                        "occurred_at_ms": "1",
                        "committed_at_ms": "2",
                        "producer": {"kind": "agent_adapter", "id": "cmux_agents"},
                        "authority": None,
                        "causation_id": None,
                        "correlation_id": None,
                        "causation_depth": 0,
                        "subjects": [],
                        "sensitivity": "metadata",
                        "payload": {},
                        "resource_revision": None,
                        "previous_resource_revision": None,
                    },
                },
            )
            release_connection.wait(1)

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                stream = client.session(SESSION).journal()
                try:
                    with self.assertRaises(cmux.ProtocolError) as raised:
                        stream.next(timeout=1)
                    self.assertIn("journal sequence must match", str(raised.exception))
                finally:
                    release_connection.set()

    def test_end_first_cancel_keeps_typed_decoder_until_response(self) -> None:
        observed = []
        disconnected = threading.Event()

        def handler(connection, _index):
            try:
                requests = frames(connection)
                opened = next(requests)
                observed.append(opened)
                stream_id = opened["params"]["stream_id"]
                ok(connection, opened, {"stream_id": stream_id})
                canceled = next(requests)
                observed.append(canceled)
                canceled_end(connection, stream_id)
                send_frame(
                    connection,
                    {
                        "protocol": "cmux.protocol/2",
                        "type": "stream_item",
                        "stream_id": stream_id,
                        "sequence": "1",
                        "item": {"kind": "snapshot"},
                    },
                )
                ok(connection, canceled, {})
                observed.extend(requests)
            finally:
                disconnected.set()

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                stream = client.session(SESSION).events()
                with self.assertRaises(cmux.ProtocolError) as raised:
                    stream.cancel()
                self.assertIn("invalid stream item", str(raised.exception))
                self.assertIsNotNone(stream.end)
                assert stream.end is not None
                self.assertEqual(stream.end.reason, "canceled")
                with self.assertRaises(cmux.ProtocolError) as repeated:
                    stream.cancel()
                self.assertIs(repeated.exception, raised.exception)
                self.assertTrue(client.closed)
                self.assertTrue(client._connection._wire.closed)
                self.assertTrue(disconnected.wait(0.5))

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )

    def test_end_first_cancel_rejects_valid_known_item_before_response(
        self,
    ) -> None:
        observed = []
        disconnected = threading.Event()

        def handler(connection, _index):
            try:
                requests = frames(connection)
                opened = next(requests)
                observed.append(opened)
                stream_id = opened["params"]["stream_id"]
                ok(connection, opened, {"stream_id": stream_id})
                canceled = next(requests)
                observed.append(canceled)
                canceled_end(connection, stream_id)
                send_frame(
                    connection,
                    {
                        "protocol": "cmux.protocol/2",
                        "type": "stream_item",
                        "stream_id": stream_id,
                        "sequence": "1",
                        "item": {
                            "kind": "delta",
                            "cursor": {
                                "generation": "generation-a",
                                "revision": "2",
                            },
                            "previous_revision": "1",
                            "revision": "2",
                            "changes": [],
                        },
                    },
                )
                ok(connection, canceled, {})
                observed.extend(requests)
            finally:
                disconnected.set()

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                stream = client.session(SESSION).events()
                with self.assertRaises(cmux.ProtocolError) as raised:
                    stream.cancel()
                self.assertIn("item arrived after stream end", str(raised.exception))
                with self.assertRaises(cmux.ProtocolError) as repeated:
                    stream.cancel()
                self.assertIs(repeated.exception, raised.exception)
                self.assertTrue(client.closed)
                self.assertTrue(client._connection._wire.closed)
                self.assertTrue(disconnected.wait(0.5))

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )

    def test_explicit_cancel_uses_one_deadline_across_stale_item_drip(
        self,
    ) -> None:
        observed = []
        disconnected = threading.Event()

        def handler(connection, _index):
            try:
                requests = frames(connection)
                opened = next(requests)
                observed.append(opened)
                stream_id = opened["params"]["stream_id"]
                ok(connection, opened, {"stream_id": stream_id})
                canceled = next(requests)
                observed.append(canceled)
                time.sleep(0.055)
                ok(connection, canceled, {})
                for sequence in range(1, 20):
                    time.sleep(0.015)
                    send_frame(
                        connection,
                        {
                            "protocol": "cmux.protocol/2",
                            "type": "stream_item",
                            "stream_id": stream_id,
                            "sequence": str(sequence),
                            "item": {
                                "kind": "future.event",
                                "stale": sequence,
                            },
                        },
                    )
            finally:
                disconnected.set()

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.05) as client:
                stream = client.session(SESSION).events()
                started = time.monotonic()
                with self.assertRaises(cmux.TimeoutError) as raised:
                    stream.cancel()
                elapsed = time.monotonic() - started
                self.assertGreaterEqual(elapsed, 0.08)
                self.assertLess(elapsed, 0.3)
                with self.assertRaises(cmux.TimeoutError) as repeated:
                    stream.cancel()
                self.assertIs(repeated.exception, raised.exception)
                self.assertTrue(client.closed)
                self.assertTrue(client._connection._wire.closed)
                self.assertTrue(disconnected.wait(0.5))

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )

    def test_explicit_cancel_end_without_response_times_out_once(self) -> None:
        observed = []
        disconnected = threading.Event()

        def handler(connection, _index):
            try:
                requests = frames(connection)
                opened = next(requests)
                observed.append(opened)
                stream_id = opened["params"]["stream_id"]
                ok(connection, opened, {"stream_id": stream_id})
                canceled = next(requests)
                observed.append(canceled)
                canceled_end(connection, stream_id)
                observed.extend(requests)
            finally:
                disconnected.set()

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.05) as client:
                stream = client.session(SESSION).events()
                started = time.monotonic()
                with self.assertRaises(cmux.TimeoutError) as raised:
                    stream.cancel()
                elapsed = time.monotonic() - started
                self.assertGreaterEqual(elapsed, 0.08)
                self.assertLess(elapsed, 0.3)
                with self.assertRaises(cmux.TimeoutError) as repeated:
                    stream.cancel()
                self.assertIs(repeated.exception, raised.exception)
                self.assertTrue(client.closed)
                self.assertTrue(client._connection._wire.closed)
                self.assertTrue(disconnected.wait(0.5))

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )

    def test_concurrent_explicit_cancel_callers_share_one_bounded_failure(
        self,
    ) -> None:
        observed = []
        cancel_seen = threading.Event()
        disconnected = threading.Event()

        def handler(connection, _index):
            try:
                requests = frames(connection)
                opened = next(requests)
                observed.append(opened)
                ok(
                    connection,
                    opened,
                    {"stream_id": opened["params"]["stream_id"]},
                )
                canceled = next(requests)
                observed.append(canceled)
                cancel_seen.set()
                list(requests)
            finally:
                disconnected.set()

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.05) as client:
                stream = client.session(SESSION).events()
                barrier = threading.Barrier(3)
                failures = []
                elapsed = []

                def cancel():
                    barrier.wait()
                    started = time.monotonic()
                    try:
                        stream.cancel()
                    except BaseException as error:
                        failures.append(error)
                    elapsed.append(time.monotonic() - started)

                callers = [threading.Thread(target=cancel) for _ in range(2)]
                for caller in callers:
                    caller.start()
                barrier.wait()
                self.assertTrue(cancel_seen.wait(1))
                for caller in callers:
                    caller.join(timeout=0.5)
                    self.assertFalse(caller.is_alive())

                self.assertEqual(len(failures), 2)
                self.assertIs(failures[0], failures[1])
                self.assertIsInstance(failures[0], cmux.TimeoutError)
                self.assertTrue(all(duration < 0.3 for duration in elapsed))
                self.assertTrue(client.closed)
                self.assertTrue(client._connection._wire.closed)
                self.assertTrue(disconnected.wait(0.5))

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )

    def test_overflow_and_public_cancel_share_one_failed_cancel_claim(
        self,
    ) -> None:
        previous_messages = resource_protocol.MAX_STREAM_MESSAGES
        observed = []
        release_items = threading.Event()
        cancel_seen = threading.Event()
        release_cancel = threading.Event()
        disconnected = threading.Event()

        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            observed.append(opened)
            stream_id = opened["params"]["stream_id"]
            ok(connection, opened, {"stream_id": stream_id})
            release_items.wait(1)
            for sequence in (1, 2):
                send_frame(
                    connection,
                    {
                        "protocol": "cmux.protocol/2",
                        "type": "stream_item",
                        "stream_id": stream_id,
                        "sequence": str(sequence),
                        "item": {"kind": "future.event"},
                    },
                )

            canceled = next(requests)
            observed.append(canceled)
            cancel_seen.set()
            release_cancel.wait(1)
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/2",
                    "type": "response",
                    "id": canceled["id"],
                    "ok": False,
                    "error": {
                        "code": "operation.failed",
                        "message": "overflow cancel fixture failed",
                        "details": {"reason": "fixture"},
                        "retryable": False,
                    },
                },
            )
            for request in requests:
                observed.append(request)
            disconnected.set()

        resource_protocol.MAX_STREAM_MESSAGES = 1
        try:
            with UnixJsonServer(handler) as server:
                with Client(server.path, timeout=0.2) as client:
                    stream = client.session(SESSION).events()
                    release_items.set()
                    self.assertTrue(cancel_seen.wait(1))
                    stream.cancel()
                    release_cancel.set()

                    deadline = time.monotonic() + 1
                    while not client.closed and time.monotonic() < deadline:
                        time.sleep(0.001)
                    self.assertTrue(client.closed)
                    self.assertTrue(client._connection._wire.closed)
                    self.assertTrue(disconnected.wait(0.5))
                    with self.assertRaises(cmux.StreamError) as raised:
                        next(stream)
                    self.assertEqual(raised.exception.reason, "gap")
        finally:
            release_items.set()
            release_cancel.set()
            resource_protocol.MAX_STREAM_MESSAGES = previous_messages

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )
        self.assertEqual(
            observed[1]["params"]["stream"],
            observed[0]["params"]["stream_id"],
        )

    def test_partial_sibling_write_closes_without_appended_cancel(self) -> None:
        observed = []
        open_seen = threading.Event()
        disconnected = threading.Event()
        remainder = []

        def handler(connection, _index):
            source = connection.makefile("rb")
            line = source.readline()
            if line:
                observed.append(json.loads(line))
                open_seen.set()
            remainder.append(source.read())
            disconnected.set()

        partial_write_error = CmuxConnectionError(
            "synthetic partial sibling write failure"
        )
        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=2) as client:
                session = client.session(SESSION)
                send_encoded = client._connection._wire._send_encoded
                send_count = 0

                def fail_second_write(encoded):
                    nonlocal send_count
                    send_count += 1
                    if send_count == 1:
                        send_encoded(encoded)
                        return
                    partial = encoded[: max(1, len(encoded) // 2)]
                    client._connection._wire._socket.sendall(partial)
                    raise partial_write_error

                open_errors = []
                open_done = threading.Event()

                def open_stream():
                    try:
                        session.events()
                    except BaseException as error:
                        open_errors.append(error)
                    finally:
                        open_done.set()

                with patch.object(
                    client._connection._wire,
                    "_send_encoded",
                    side_effect=fail_second_write,
                ):
                    open_thread = threading.Thread(target=open_stream)
                    open_thread.start()
                    self.assertTrue(open_seen.wait(1))
                    with client._connection._lock:
                        open_state = next(
                            iter(client._connection._streams.values())
                        )
                    with self.assertRaises(CmuxConnectionError) as raised:
                        session.ping()
                    self.assertIs(raised.exception, partial_write_error)
                    self.assertTrue(open_done.wait(1))
                    open_thread.join(timeout=1)
                    self.assertFalse(open_thread.is_alive())

                self.assertEqual(open_errors, [partial_write_error])
                self.assertTrue(client.closed)
                self.assertTrue(client._connection._wire.closed)
                self.assertTrue(disconnected.wait(0.5))
                self.assertFalse(open_state.cancel_dispatch_started)

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events"],
        )
        self.assertEqual(len(remainder), 1)
        self.assertTrue(remainder[0])
        self.assertFalse(remainder[0].endswith(b"\n"))
        self.assertNotIn(b'"operation":"stream.cancel"', remainder[0])

    def test_failed_open_cleanup_and_reader_failure_share_cancel_dispatch(
        self,
    ) -> None:
        observed = []
        cleanup_claimed = threading.Event()
        disconnected = threading.Event()

        def handler(connection, _index):
            requests = frames(connection)
            opened = next(requests)
            observed.append(opened)
            cleanup_claimed.wait(1)
            send_frame(
                connection,
                {
                    "protocol": "cmux.protocol/future",
                    "type": "response",
                    "id": opened["id"],
                    "ok": True,
                    "result": {
                        "stream_id": opened["params"]["stream_id"],
                    },
                },
            )
            for request in requests:
                observed.append(request)
            disconnected.set()

        with UnixJsonServer(handler) as server:
            with Client(server.path, timeout=0.2) as client:
                request_cancel = client._connection._request_stream_cancel

                def wait_for_reader_failure(
                    state,
                    *,
                    failed_open,
                    operation=None,
                ):
                    cleanup_claimed.set()
                    deadline = time.monotonic() + 1
                    while not client.closed and time.monotonic() < deadline:
                        time.sleep(0.001)
                    if not client.closed:
                        raise AssertionError("reader did not fail the connection")
                    return request_cancel(
                        state,
                        failed_open=failed_open,
                        operation=operation,
                    )

                with patch.object(
                    client._connection,
                    "_request_stream_cancel",
                    side_effect=wait_for_reader_failure,
                ):
                    with self.assertRaises(cmux.TimeoutError) as raised:
                        client.with_request_options(
                            RequestOptions(timeout=0.02),
                            client.session(SESSION).events,
                        )
                self.assertIn("did not respond", str(raised.exception))
                self.assertTrue(client.closed)
                self.assertTrue(disconnected.wait(0.5))
                self.assertTrue(client._connection._wire.closed)
                self.assertEqual(client._connection._streams, {})

        self.assertEqual(
            [request["operation"] for request in observed],
            ["session.events", "stream.cancel"],
        )
        self.assertEqual(
            observed[1]["params"]["stream"],
            observed[0]["params"]["stream_id"],
        )

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
                    "protocol": "cmux.protocol/2",
                    "type": "stream_item",
                    "stream_id": stream_id,
                    "sequence": "1",
                    "item": {"kind": "future.event", "value": 1},
                },
            )
            canceled = next(requests)
            canceled_end(connection, stream_id)
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
                    "protocol": "cmux.protocol/2",
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
                                    "tab_ids": [str(TAB)],
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
                    "protocol": "cmux.protocol/2",
                    "type": "stream_item",
                    "stream_id": stream_id,
                    "sequence": "2",
                    "item": {"kind": "future.event", "opaque": True},
                },
            )
            canceled = next(requests)
            ok(connection, canceled, {})
            canceled_end(connection, stream_id)

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
                            "protocol": "cmux.protocol/2",
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
                    "protocol": "cmux.protocol/2",
                    "type": "stream_item",
                    "stream_id": stream_id,
                    "sequence": "1",
                    "item": {"kind": "later"},
                },
            )
            canceled = next(requests)
            canceled_end(connection, stream_id)
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
        observed = []

        def handler(connection, _index):
            requests = frames(connection)
            wait = next(requests)
            observed.append(wait)
            request_seen.set()
            cancel = next(requests)
            observed.append(cancel)
            ok(connection, cancel, {"canceled": True})
            ping = next(requests)
            observed.append(ping)
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
            terminal = client.session(SESSION).terminal(TERMINAL)
            task = asyncio.create_task(
                terminal.wait(cmux.TerminalWaitOptions("never"))
            )
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

        self.assertEqual(
            [request["operation"] for request in observed],
            ["terminal.wait", "request.cancel", "session.ping"],
        )
        self.assertEqual(
            observed[1]["params"],
            {"request_id": observed[0]["id"]},
        )

        leaked = [
            thread.name
            for thread in threading.enumerate()
            if thread.name.startswith(("cmux-aio", "cmux-resource-reader-"))
        ]
        self.assertEqual(leaked, [])


if __name__ == "__main__":
    unittest.main()
