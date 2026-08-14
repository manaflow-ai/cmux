from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Literal, Tuple


OperationClass = Literal[
    "read",
    "mutation",
    "stream_open",
    "connection_control",
    "local",
]


@dataclass(frozen=True)
class Operation:
    wire_name: str
    operation_class: OperationClass
    selectors: Tuple[str, ...] = ()
    result: str = "document"

    @property
    def is_mutation(self) -> bool:
        return self.operation_class == "mutation"

    @property
    def accepts_expected_revision(self) -> bool:
        return self.is_mutation


def _op(
    wire_name: str,
    operation_class: OperationClass,
    selectors: Tuple[str, ...] = (),
    result: str = "document",
) -> Operation:
    return Operation(wire_name, operation_class, selectors, result)


class Operations:
    MACHINE_LIST = _op("machine.list", "read", result="machine_list")
    MACHINE_GET = _op("machine.get", "read", ("machine",), "machine")

    SESSION_LIST = _op("session.list", "read", ("machine",), "session_list")
    SESSION_OPEN = _op(
        "session.open", "mutation", ("machine", "session"), "session"
    )
    SESSION_GET = _op("session.get", "read", ("session",), "session")
    SESSION_CREATION_RESOLVE = _op(
        "session.creation.resolve", "read", ("session",), "creation_resolution"
    )
    SESSION_SNAPSHOT = _op("session.snapshot", "read", ("session",), "session")
    SESSION_EVENTS = _op("session.events", "stream_open", ("session",), "stream")
    SESSION_JOURNAL_SUBSCRIBE = _op(
        "session.journal.subscribe", "stream_open", ("session",), "stream"
    )
    SESSION_PING = _op("session.ping", "read", ("session",))
    SESSION_SHUTDOWN = _op("session.shutdown", "mutation", ("session",))
    SESSION_RELOAD_CONFIG = _op("session.reload_config", "mutation", ("session",))
    SESSION_TERMINAL_DEFAULTS_UPDATE = _op(
        "session.terminal_defaults.update", "mutation", ("session",)
    )

    CLIENT_LIST = _op("client.list", "read", ("session",), "client_list")
    CLIENT_GET = _op(
        "client.get", "read", ("session", "client"), "connected_client"
    )
    CLIENT_METADATA_UPDATE = _op(
        "client.metadata.update",
        "connection_control",
        ("session", "client"),
        "connected_client",
    )
    CLIENT_SIZING_SET = _op(
        "client.sizing.set", "connection_control", ("session", "client")
    )
    CLIENT_SIZING_RELEASE = _op(
        "client.sizing.release", "connection_control", ("session", "client")
    )
    CLIENT_CELL_PIXELS_SET = _op(
        "client.cell_pixels.set", "connection_control", ("session", "client")
    )
    CLIENT_DETACH = _op(
        "client.detach", "connection_control", ("session", "client")
    )

    WINDOW_TITLE_SET = _op(
        "session.window.title.set", "mutation", ("session",)
    )
    WINDOW_TITLE_CLEAR = _op(
        "session.window.title.clear", "mutation", ("session",)
    )

    PAIRING_REQUEST_LIST = _op(
        "pairing_request.list", "read", ("session",), "pairing_request_list"
    )
    PAIRING_REQUEST_RESOLVE = _op(
        "pairing_request.resolve",
        "mutation",
        ("session", "pairing_request"),
        "pairing_request",
    )

    FRONTEND_PROJECTION_GET = _op(
        "frontend_projection.get",
        "read",
        ("session",),
        "frontend_projection",
    )
    FRONTEND_PROJECTION_PUT = _op(
        "frontend_projection.put",
        "mutation",
        ("session",),
        "frontend_projection",
    )

    WORKSPACE_LIST = _op(
        "workspace.list", "read", ("session",), "workspace_list"
    )
    WORKSPACE_GET = _op(
        "workspace.get", "read", ("session", "workspace"), "workspace"
    )
    WORKSPACE_CREATE = _op(
        "workspace.create", "mutation", ("session",), "created"
    )
    WORKSPACE_RENAME = _op(
        "workspace.rename",
        "mutation",
        ("session", "workspace"),
        "workspace",
    )
    WORKSPACE_MOVE = _op(
        "workspace.move", "mutation", ("session", "workspace"), "workspace"
    )
    WORKSPACE_FOCUS = _op(
        "workspace.focus", "mutation", ("session", "workspace"), "workspace"
    )
    WORKSPACE_CLOSE = _op(
        "workspace.close", "mutation", ("session", "workspace")
    )
    WORKSPACE_RUN = _op(
        "workspace.run", "mutation", ("session", "workspace"), "created"
    )
    WORKSPACE_LAYOUT_APPLY = _op(
        "workspace.layout.apply", "mutation", ("session", "workspace")
    )

    SCREEN_LIST = _op(
        "screen.list", "read", ("session", "workspace"), "screen_list"
    )
    SCREEN_GET = _op(
        "screen.get",
        "read",
        ("session", "workspace", "screen"),
        "screen",
    )
    SCREEN_CREATE = _op(
        "screen.create", "mutation", ("session", "workspace"), "screen"
    )
    SCREEN_RENAME = _op(
        "screen.rename",
        "mutation",
        ("session", "workspace", "screen"),
        "screen",
    )
    SCREEN_FOCUS = _op(
        "screen.focus",
        "mutation",
        ("session", "workspace", "screen"),
        "screen",
    )
    SCREEN_CLOSE = _op(
        "screen.close", "mutation", ("session", "workspace", "screen")
    )
    SCREEN_LAYOUT_EXPORT = _op(
        "screen.layout.export",
        "read",
        ("session", "workspace", "screen"),
    )
    SCREEN_LAYOUT_UNDO = _op(
        "screen.layout.undo",
        "mutation",
        ("session", "workspace", "screen"),
    )

    PANE_LIST = _op(
        "pane.list",
        "read",
        ("session", "workspace", "screen"),
        "pane_list",
    )
    PANE_GET = _op(
        "pane.get",
        "read",
        ("session", "workspace", "screen", "pane"),
        "pane",
    )
    PANE_CREATE = _op(
        "pane.create",
        "mutation",
        ("session", "workspace", "screen"),
        "pane",
    )
    PANE_SPLIT = _op(
        "pane.split",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "pane",
    )
    PANE_RENAME = _op(
        "pane.rename",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "pane",
    )
    PANE_FOCUS = _op(
        "pane.focus",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "pane",
    )
    PANE_FOCUS_DIRECTION = _op(
        "pane.focus_direction",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "pane",
    )
    PANE_NEIGHBOR_GET = _op(
        "pane.neighbor.get",
        "read",
        ("session", "workspace", "screen", "pane"),
        "pane",
    )
    PANE_SWAP = _op(
        "pane.swap",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "pane",
    )
    PANE_ZOOM = _op(
        "pane.zoom",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "pane",
    )
    PANE_SPLIT_RATIO_SET = _op(
        "pane.split_ratio.set",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "pane",
    )
    PANE_VIEWPORT_WIDTH_SET = _op(
        "pane.viewport_width.set",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "pane",
    )
    PANE_CLOSE = _op(
        "pane.close",
        "mutation",
        ("session", "workspace", "screen", "pane"),
    )
    PANE_RUN = _op(
        "pane.run",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "created",
    )

    TAB_LIST = _op(
        "tab.list",
        "read",
        ("session", "workspace", "screen", "pane"),
        "tab_list",
    )
    TAB_GET = _op(
        "tab.get",
        "read",
        ("session", "workspace", "screen", "pane", "tab"),
        "tab",
    )
    TAB_CREATE_TERMINAL = _op(
        "tab.create_terminal",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "created",
    )
    TAB_CREATE_BROWSER = _op(
        "tab.create_browser",
        "mutation",
        ("session", "workspace", "screen", "pane"),
        "created",
    )
    TAB_RENAME = _op(
        "tab.rename",
        "mutation",
        ("session", "workspace", "screen", "pane", "tab"),
        "tab",
    )
    TAB_MOVE = _op(
        "tab.move",
        "mutation",
        ("session", "workspace", "screen", "pane", "tab"),
        "tab",
    )
    TAB_FOCUS = _op(
        "tab.focus",
        "mutation",
        ("session", "workspace", "screen", "pane", "tab"),
        "tab",
    )
    TAB_CLOSE = _op(
        "tab.close",
        "mutation",
        ("session", "workspace", "screen", "pane", "tab"),
    )

    TERMINAL_LIST = _op(
        "terminal.list", "read", ("session",), "terminal_list"
    )
    TERMINAL_GET = _op(
        "terminal.get", "read", ("session", "terminal"), "terminal"
    )
    TERMINAL_INPUT_WRITE = _op(
        "terminal.input.write", "mutation", ("session", "terminal")
    )
    TERMINAL_INPUT_KEYS = _op(
        "terminal.input.keys", "mutation", ("session", "terminal")
    )
    TERMINAL_INPUT_MOUSE = _op(
        "terminal.input.mouse", "mutation", ("session", "terminal")
    )
    TERMINAL_INPUT_FOCUS = _op(
        "terminal.input.focus", "mutation", ("session", "terminal")
    )
    TERMINAL_SCREEN_READ = _op(
        "terminal.screen.read", "read", ("session", "terminal")
    )
    TERMINAL_STATE_READ = _op(
        "terminal.state.read", "read", ("session", "terminal")
    )
    TERMINAL_HISTORY_READ = _op(
        "terminal.history.read", "read", ("session", "terminal")
    )
    TERMINAL_HISTORY_CLEAR = _op(
        "terminal.history.clear", "mutation", ("session", "terminal")
    )
    TERMINAL_WAIT = _op(
        "terminal.wait", "read", ("session", "terminal")
    )
    TERMINAL_WAIT_EXIT = _op(
        "terminal.wait_exit", "read", ("session", "terminal")
    )
    TERMINAL_COPY = _op(
        "terminal.copy", "read", ("session", "terminal")
    )
    TERMINAL_PROCESS_GET = _op(
        "terminal.process.get", "read", ("session", "terminal")
    )
    TERMINAL_RENDERER_GRANT_CREATE = _op(
        "terminal.renderer_grant.create",
        "connection_control",
        ("session", "terminal"),
    )
    TERMINAL_VIEWER_RESIZE = _op(
        "terminal.viewer.resize",
        "connection_control",
        ("session", "terminal"),
    )
    TERMINAL_VIEWER_RELEASE = _op(
        "terminal.viewer.release",
        "connection_control",
        ("session", "terminal"),
    )
    TERMINAL_VIEWPORT_SCROLL = _op(
        "terminal.viewport.scroll", "mutation", ("session", "terminal")
    )
    TERMINAL_MOVE = _op(
        "terminal.move", "mutation", ("session", "terminal"), "terminal"
    )
    TERMINAL_PROJECT = _op(
        "terminal.project", "mutation", ("session", "terminal"), "tab"
    )
    TERMINAL_ATTACH = _op(
        "terminal.attach", "stream_open", ("session", "terminal"), "stream"
    )
    TERMINAL_CLOSE = _op(
        "terminal.close", "mutation", ("session", "terminal")
    )

    BROWSER_LIST = _op("browser.list", "read", ("session",), "browser_list")
    BROWSER_GET = _op(
        "browser.get", "read", ("session", "browser"), "browser"
    )
    BROWSER_NAVIGATE = _op(
        "browser.navigate", "mutation", ("session", "browser"), "browser"
    )
    BROWSER_BACK = _op(
        "browser.back", "mutation", ("session", "browser"), "browser"
    )
    BROWSER_FORWARD = _op(
        "browser.forward", "mutation", ("session", "browser"), "browser"
    )
    BROWSER_RELOAD = _op(
        "browser.reload", "mutation", ("session", "browser"), "browser"
    )
    BROWSER_ACTIVATE = _op(
        "browser.activate", "mutation", ("session", "browser"), "browser"
    )
    BROWSER_INPUT_KEY = _op(
        "browser.input.key", "mutation", ("session", "browser")
    )
    BROWSER_INPUT_TEXT = _op(
        "browser.input.text", "mutation", ("session", "browser")
    )
    BROWSER_INPUT_MOUSE = _op(
        "browser.input.mouse", "mutation", ("session", "browser")
    )
    BROWSER_INPUT_WHEEL = _op(
        "browser.input.wheel", "mutation", ("session", "browser")
    )
    BROWSER_VIEWER_RESIZE = _op(
        "browser.viewer.resize",
        "connection_control",
        ("session", "browser"),
    )
    BROWSER_VIEWER_RELEASE = _op(
        "browser.viewer.release",
        "connection_control",
        ("session", "browser"),
    )
    BROWSER_ATTACH = _op(
        "browser.attach", "stream_open", ("session", "browser"), "stream"
    )
    BROWSER_CLOSE = _op(
        "browser.close", "mutation", ("session", "browser")
    )

    NOTIFICATION_LIST = _op(
        "notification.list", "read", ("session",), "notification_list"
    )
    NOTIFICATION_CREATE = _op(
        "notification.create", "mutation", ("session",), "notification"
    )
    AGENT_LIST = _op("agent.list", "read", ("session",), "agent_list")
    AGENT_REPORT = _op(
        "agent.report", "mutation", ("session",), "agent"
    )

    SIDEBAR_VIEW_GET = _op(
        "sidebar_view.get", "read", ("session", "sidebar_view"), "sidebar_view"
    )
    SIDEBAR_VIEW_ENSURE = _op(
        "sidebar_view.ensure",
        "mutation",
        ("session", "sidebar_view"),
        "sidebar_view",
    )
    SIDEBAR_VIEW_ATTACH = _op(
        "sidebar_view.attach",
        "stream_open",
        ("session", "sidebar_view"),
        "stream",
    )
    SIDEBAR_VIEW_INPUT = _op(
        "sidebar_view.input", "mutation", ("session", "sidebar_view")
    )
    SIDEBAR_VIEW_RESIZE = _op(
        "sidebar_view.resize", "mutation", ("session", "sidebar_view")
    )
    SIDEBAR_VIEW_RELOAD = _op(
        "sidebar_view.reload", "mutation", ("session", "sidebar_view")
    )

    REQUEST_CANCEL = _op("request.cancel", "connection_control")
    STREAM_CANCEL = _op(
        "stream.cancel", "connection_control", ("stream",)
    )

    SIDEBAR_PLUGIN_LIST = _op(
        "sidebar_plugin.list", "local", result="sidebar_plugin_list"
    )
    SIDEBAR_PLUGIN_INSTALL = _op(
        "sidebar_plugin.install", "local", result="sidebar_plugin"
    )
    SIDEBAR_PLUGIN_USE = _op(
        "sidebar_plugin.use", "local", ("sidebar_plugin",), "sidebar_plugin"
    )
    SIDEBAR_PLUGIN_UPDATE = _op(
        "sidebar_plugin.update", "local", ("sidebar_plugin",), "sidebar_plugin"
    )
    SIDEBAR_PLUGIN_REMOVE = _op(
        "sidebar_plugin.remove", "local", ("sidebar_plugin",)
    )
    SIDEBAR_PLUGIN_USE_BUILTIN = _op(
        "sidebar_plugin.use_builtin", "local", result="sidebar_plugin"
    )


ALL_OPERATIONS: Dict[str, Operation] = {
    value.wire_name: value
    for value in vars(Operations).values()
    if isinstance(value, Operation)
}


__all__ = ["ALL_OPERATIONS", "Operation", "OperationClass", "Operations"]
