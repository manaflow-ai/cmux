from __future__ import annotations

from dataclasses import dataclass, field
from typing import (
    Any,
    Generic,
    Literal,
    Mapping,
    Optional,
    Sequence,
    Tuple,
    TypeVar,
    Union,
)

from .ids import (
    AgentId,
    BrowserId,
    ConnectedClientId,
    MachineId,
    NotificationId,
    PairingRequestId,
    PaneId,
    ProjectionId,
    ProviderActionId,
    ProviderNoticeId,
    ProviderScopeId,
    ResourceId,
    ScreenId,
    SessionId,
    SidebarViewId,
    SplitId,
    StreamId,
    TabId,
    TerminalId,
    WorkspaceId,
)


JsonObject = Mapping[str, Any]
ProviderActionValue = Union[str, int]
IdT = TypeVar("IdT", bound=ResourceId)
ValueT = TypeVar("ValueT")
ItemT = TypeVar("ItemT")


@dataclass(frozen=True)
class Snapshot(Generic[IdT]):
    id: IdT


@dataclass(frozen=True)
class MachineSnapshot(Snapshot[MachineId]):
    name: str
    origin: Literal["local", "external"]
    status: Literal[
        "running",
        "connecting",
        "sleeping",
        "stopped",
        "unavailable",
    ]
    connectable: bool
    deleted: bool
    recoverable: bool
    provider_scope_id: Optional[ProviderScopeId] = None
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class SessionSnapshot(Snapshot[SessionId]):
    machine_id: MachineId
    generation: str
    revision: str
    connected: bool
    name: Optional[str] = None
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class WorkspaceSnapshot(Snapshot[WorkspaceId]):
    session_id: SessionId
    name: str
    index: int
    focused: bool
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class ScreenSnapshot(Snapshot[ScreenId]):
    workspace_id: WorkspaceId
    name: Optional[str]
    index: int
    focused: bool
    layout: "LayoutDocument"
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class PaneSnapshot(Snapshot[PaneId]):
    screen_id: ScreenId
    name: Optional[str]
    focused: bool
    zoomed: bool
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class TabSnapshot(Snapshot[TabId]):
    pane_id: PaneId
    name: Optional[str]
    index: int
    focused: bool
    content_kind: Literal["terminal", "browser"]
    content_id: Union[TerminalId, BrowserId]
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class TerminalSnapshot(Snapshot[TerminalId]):
    tab_id: TabId
    title: str
    cols: int
    rows: int
    running: bool
    cwd: Optional[str] = None
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class BrowserSnapshot(Snapshot[BrowserId]):
    tab_id: TabId
    url: str
    title: str
    loading: bool
    source: Literal["external", "launched"]
    status: Literal["starting", "live", "failed"]
    error: Optional[str]
    frames_stalled: bool
    size: "Size"
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class ClientSnapshot(Snapshot[ConnectedClientId]):
    session_id: SessionId
    name: Optional[str]
    client_kind: Optional[str]
    transport: Literal["unix", "websocket"]
    connected_seconds: str
    attached_terminal_ids: Tuple[TerminalId, ...]
    sizes: Tuple["ClientTerminalSize", ...]
    self: bool
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class NotificationSnapshot(Snapshot[NotificationId]):
    session_id: SessionId
    title: str
    body: str
    level: Literal["info", "warning", "error"]
    created_at_ms: str
    unread: bool
    terminal_id: Optional[TerminalId] = None
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class AgentSnapshot(Snapshot[AgentId]):
    session_id: SessionId
    terminal_id: TerminalId
    state: Literal["working", "blocked", "idle", "done", "unknown"]
    source: Literal["hook", "socket", "detected"]
    updated_at_ms: str
    source_session: Optional[str]
    extra: JsonObject = field(default_factory=dict)


class PairingCode:
    """Explicitly revealed pairing secret with redacted string rendering."""

    __slots__ = ("__value",)

    def __init__(self, value: str) -> None:
        if not isinstance(value, str) or not value:
            raise ValueError("pairing code must be a non-empty string")
        self.__value = value

    def reveal(self) -> str:
        return self.__value

    def __repr__(self) -> str:
        return "PairingCode(<redacted>)"

    def __str__(self) -> str:
        return "<redacted>"


@dataclass(frozen=True)
class PairingRequestSnapshot(Snapshot[PairingRequestId]):
    session_id: SessionId
    peer: str
    code: PairingCode
    expires_in_seconds: str
    status: Literal["pending", "accepted", "rejected"]
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class FrontendProjectionSnapshot(Snapshot[ProjectionId]):
    session_id: SessionId
    projection: Any
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class SidebarViewSnapshot(Snapshot[SidebarViewId]):
    session_id: SessionId
    cols: int
    rows: int
    running: bool
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class ProviderScopeSnapshot(Snapshot[ProviderScopeId]):
    name: str
    kind: Literal["personal", "team"]
    can_admin: bool
    selected: bool
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class ProviderActionField:
    id: str
    label: str
    kind: Literal["text", "email", "integer"]
    required: bool
    max_length: Optional[int] = None
    minimum: Optional[int] = None
    maximum: Optional[int] = None
    placeholder: Optional[str] = None


@dataclass(frozen=True)
class ProviderActionSnapshot(Snapshot[ProviderActionId]):
    provider_scope_id: ProviderScopeId
    name: str
    title: str
    enabled: bool
    target: Literal["scope", "selected_machine", "selected_workspace"]
    destructive: bool
    fields: Tuple[ProviderActionField, ...]
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class ProviderNoticeSnapshot(Snapshot[ProviderNoticeId]):
    provider_scope_id: ProviderScopeId
    level: Literal["info", "warning", "error"]
    message: str
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class Cursor:
    generation: str
    revision: str


@dataclass(frozen=True)
class MutationResult(Generic[ValueT]):
    value: ValueT
    generation: str
    revision: str
    replayed: bool


@dataclass(frozen=True)
class Document:
    fields: JsonObject


class _Secret:
    __slots__ = ("__value", "__used")
    _label = "secret"

    def __init__(self, value: str) -> None:
        if not isinstance(value, str) or not value:
            raise ValueError(f"{self._label} must be a non-empty string")
        self.__value = value
        self.__used = False

    def take(self) -> str:
        if self.__used:
            raise RuntimeError(f"{self._label} was already consumed")
        self.__used = True
        return self.__value

    def __repr__(self) -> str:
        return f"{type(self).__name__}(<redacted>)"

    def __str__(self) -> str:
        return "<redacted>"


class RendererGrant(_Secret):
    """One-use renderer credential with redacted display."""

    _label = "renderer grant"

    def __init__(
        self,
        token: str,
        *,
        endpoint: str,
        terminal_id: TerminalId,
        rights: Sequence[str],
        ttl_ms: int,
    ) -> None:
        super().__init__(token)
        self.endpoint = endpoint
        self.terminal_id = terminal_id
        self.rights = tuple(rights)
        self.ttl_ms = ttl_ms


class ProviderCredential(_Secret):
    """Provider credential with redacted display."""

    _label = "provider credential"

    def __init__(self, name: str, value: str) -> None:
        if not isinstance(name, str) or not name:
            raise ValueError("provider credential name must be non-empty")
        self.name = name
        super().__init__(value)

    def to_params(self) -> dict[str, str]:
        return {"name": self.name, "value": self.take()}


class ExternalMachineSpecifier(_Secret):
    """One-use provider-owned machine specifier with redacted display."""

    _label = "external machine specifier"


@dataclass(frozen=True)
class ExactCommand:
    """An exact argv vector with optional process context."""

    argv: Tuple[str, ...]
    cwd: Optional[str] = None

    @classmethod
    def exact(
        cls,
        argv: Sequence[str],
        *,
        cwd: Optional[str] = None,
    ) -> "ExactCommand":
        values = tuple(argv)
        if not values or not values[0]:
            raise ValueError("argv must contain a non-empty executable")
        if any(not isinstance(value, str) for value in values):
            raise TypeError("every argv item must be a string")
        if cwd is not None and not isinstance(cwd, str):
            raise TypeError("cwd must be a string")
        return cls(values, cwd)

    def to_params(self) -> dict[str, Any]:
        params: dict[str, Any] = {"argv": list(self.argv)}
        if self.cwd is not None:
            params["cwd"] = self.cwd
        return params


@dataclass(frozen=True)
class ShellCommand:
    """A script the target session expands with its own platform shell."""

    script: str
    cwd: Optional[str] = None

    def __post_init__(self) -> None:
        if not isinstance(self.script, str):
            raise TypeError("shell script must be a string")
        if not self.script:
            raise ValueError("shell script must be non-empty")
        if self.cwd is not None and not isinstance(self.cwd, str):
            raise TypeError("cwd must be a string")

    def to_params(self) -> dict[str, Any]:
        params: dict[str, Any] = {"shell": self.script}
        if self.cwd is not None:
            params["cwd"] = self.cwd
        return params


Command = Union[ExactCommand, ShellCommand]


def exact(
    argv: Sequence[str],
    *,
    cwd: Optional[str] = None,
) -> ExactCommand:
    return ExactCommand.exact(argv, cwd=cwd)


def shell(
    script: str,
    *,
    cwd: Optional[str] = None,
) -> ShellCommand:
    """Explicitly request target-side shell evaluation."""

    if not isinstance(script, str):
        raise TypeError("shell command must be a string")
    if not script:
        raise ValueError("shell command must be non-empty")
    return ShellCommand(script, cwd=cwd)


def shell_executable(
    executable: str,
    script: str,
    *,
    cwd: Optional[str] = None,
) -> ExactCommand:
    """Choose a shell explicitly without inspecting or expanding the script."""

    return exact((executable, "-lc", script), cwd=cwd)


@dataclass(frozen=True)
class KeyInput:
    key: str
    action: Optional[str] = None
    modifiers: Tuple[str, ...] = ()
    text: Optional[str] = None


@dataclass(frozen=True)
class MouseInput:
    kind: str
    x: Optional[float] = None
    y: Optional[float] = None
    button: Optional[str] = None
    modifiers: Tuple[str, ...] = ()


@dataclass(frozen=True)
class Size:
    cols: int
    rows: int


@dataclass(frozen=True)
class LayoutLeaf:
    kind: Literal["leaf"]
    pane_id: PaneId
    tab_ids: Tuple[TabId, ...]
    active_tab_id: Optional[TabId] = None


@dataclass(frozen=True)
class LayoutSplit:
    kind: Literal["split"]
    split_id: "SplitId"
    direction: Literal["horizontal", "vertical"]
    ratio: float
    first: "LayoutNode"
    second: "LayoutNode"


@dataclass(frozen=True)
class LayoutStack:
    kind: Literal["stack"]
    pane_ids: Tuple[PaneId, ...]
    expanded_pane_id: PaneId


@dataclass(frozen=True)
class LayoutColumn:
    column_id: "SplitId"
    width: float
    root: "LayoutNode"


@dataclass(frozen=True)
class LayoutViewport:
    kind: Literal["viewport"]
    base_width: float
    columns: Tuple[LayoutColumn, ...]


LayoutNode = Union[LayoutLeaf, LayoutSplit, LayoutStack, LayoutViewport]


@dataclass(frozen=True)
class LayoutDocument:
    screen_id: ScreenId
    active_pane_id: PaneId
    zoomed_pane_id: Optional[PaneId]
    root: LayoutNode
    version: int
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class PixelSize:
    width_px: int
    height_px: int


@dataclass(frozen=True)
class ClientTerminalSize:
    terminal_id: TerminalId
    cols: Optional[int]
    rows: Optional[int]
    participating: bool


@dataclass(frozen=True)
class StreamItem(Generic[ItemT]):
    stream_id: StreamId
    sequence: str
    item: ItemT
    cursor: Optional[Cursor] = None


@dataclass(frozen=True)
class StreamEnd:
    stream_id: StreamId
    reason: str
    cursor: Optional[Cursor] = None
    error: Optional[BaseException] = None
    recovery: Optional[str] = None


@dataclass(frozen=True)
class ResourceSnapshot:
    machine: MachineSnapshot
    session: SessionSnapshot
    workspaces: Tuple[WorkspaceSnapshot, ...]
    screens: Tuple[ScreenSnapshot, ...]
    panes: Tuple[PaneSnapshot, ...]
    tabs: Tuple[TabSnapshot, ...]
    terminals: Tuple[TerminalSnapshot, ...]
    browsers: Tuple[BrowserSnapshot, ...]
    clients: Tuple[ClientSnapshot, ...]
    notifications: Tuple[NotificationSnapshot, ...]
    agents: Tuple[AgentSnapshot, ...]
    frontend_projections: Tuple[FrontendProjectionSnapshot, ...]
    sidebar_views: Tuple[SidebarViewSnapshot, ...]
    cursor: Cursor
    extra: JsonObject = field(default_factory=dict)


ResourceKind = Literal[
    "machine",
    "session",
    "workspace",
    "screen",
    "pane",
    "tab",
    "terminal",
    "browser",
    "client",
    "notification",
    "agent",
    "pairing_request",
    "frontend_projection",
    "sidebar_view",
    "provider_scope",
    "provider_action",
    "provider_notice",
]
ResourceEntitySnapshot = Union[
    MachineSnapshot,
    SessionSnapshot,
    WorkspaceSnapshot,
    ScreenSnapshot,
    PaneSnapshot,
    TabSnapshot,
    TerminalSnapshot,
    BrowserSnapshot,
    ClientSnapshot,
    NotificationSnapshot,
    AgentSnapshot,
    PairingRequestSnapshot,
    FrontendProjectionSnapshot,
    SidebarViewSnapshot,
    ProviderScopeSnapshot,
    ProviderActionSnapshot,
    ProviderNoticeSnapshot,
]


@dataclass(frozen=True)
class ResourceUpsert:
    kind: Literal["upsert"]
    sequence: int
    resource: ResourceKind
    id: ResourceId
    value: ResourceEntitySnapshot


@dataclass(frozen=True)
class ResourceDelete:
    kind: Literal["delete"]
    sequence: int
    resource: ResourceKind
    id: ResourceId


@dataclass(frozen=True)
class Unknown:
    kind: str
    raw: JsonObject


ResourceChange = Union[ResourceUpsert, ResourceDelete, Unknown]


@dataclass(frozen=True)
class SessionSnapshotItem:
    kind: Literal["snapshot"]
    cursor: Cursor
    snapshot: ResourceSnapshot
    reset_reason: Optional[
        Literal["initial", "generation_changed", "cursor_expired"]
    ] = None


@dataclass(frozen=True)
class SessionDelta:
    kind: Literal["delta"]
    cursor: Cursor
    previous_revision: str
    revision: str
    changes: Tuple[ResourceChange, ...]


SessionEvent = Union[SessionSnapshotItem, SessionDelta, Unknown]


@dataclass(frozen=True)
class RenderCursor:
    x: int
    y: int
    style: Literal["block", "underline", "bar"]
    blink: bool
    visible: bool
    color: Optional[str]


@dataclass(frozen=True)
class RenderRun:
    text: str
    fg: Optional[str]
    bg: Optional[str]
    attrs: int
    underline: Optional[
        Literal["single", "double", "curly", "dotted", "dashed"]
    ] = None
    width_hint: Optional[int] = None


@dataclass(frozen=True)
class RenderRow:
    row: int
    runs: Tuple[RenderRun, ...]


@dataclass(frozen=True)
class RenderSnapshot:
    size: Size
    cursor: RenderCursor
    default_fg: str
    default_bg: str
    scrollback_rows: int
    rows: Tuple[RenderRow, ...]


@dataclass(frozen=True)
class RenderPatch:
    cursor: RenderCursor
    full_reset: bool
    rows: Tuple[RenderRow, ...]
    size: Optional[Size] = None
    default_fg: Optional[str] = None
    default_bg: Optional[str] = None
    scrollback_rows: Optional[int] = None


@dataclass(frozen=True)
class RenderScroll:
    offset: str
    at_bottom: bool


@dataclass(frozen=True)
class TerminalAttachSnapshot:
    kind: Literal["snapshot"]
    terminal_id: TerminalId
    render: RenderSnapshot


@dataclass(frozen=True)
class TerminalAttachPatch:
    kind: Literal["patch"]
    terminal_id: TerminalId
    render: RenderPatch


@dataclass(frozen=True)
class TerminalAttachScroll:
    kind: Literal["scroll"]
    terminal_id: TerminalId
    scroll: RenderScroll


TerminalAttachItem = Union[
    TerminalAttachSnapshot,
    TerminalAttachPatch,
    TerminalAttachScroll,
    Unknown,
]


@dataclass(frozen=True)
class BrowserAttachSnapshot:
    kind: Literal["snapshot"]
    browser: BrowserSnapshot
    size: PixelSize


@dataclass(frozen=True)
class BrowserAttachFrame:
    kind: Literal["frame"]
    mime_type: Literal["image/png", "image/jpeg"]
    data_base64: str
    width_px: int
    height_px: int


@dataclass(frozen=True)
class BrowserAttachState:
    kind: Literal["state"]
    url: str
    title: str
    loading: bool


BrowserAttachItem = Union[
    BrowserAttachSnapshot,
    BrowserAttachFrame,
    BrowserAttachState,
    Unknown,
]


@dataclass(frozen=True)
class SidebarAttachSnapshot:
    kind: Literal["snapshot"]
    sidebar_view: SidebarViewSnapshot
    render: RenderSnapshot


@dataclass(frozen=True)
class SidebarAttachPatch:
    kind: Literal["patch"]
    sidebar_view_id: SidebarViewId
    render: RenderPatch


@dataclass(frozen=True)
class SidebarAttachScroll:
    kind: Literal["scroll"]
    sidebar_view_id: SidebarViewId
    scroll: RenderScroll


SidebarAttachItem = Union[
    SidebarAttachSnapshot,
    SidebarAttachPatch,
    SidebarAttachScroll,
    Unknown,
]


@dataclass(frozen=True)
class ProviderNoticeKnown:
    kind: Literal["notice"]
    notice: ProviderNoticeSnapshot
    sequence: str


ProviderNoticeItem = Union[ProviderNoticeKnown, Unknown]


__all__ = [
    "AgentSnapshot",
    "BrowserAttachFrame",
    "BrowserAttachItem",
    "BrowserAttachSnapshot",
    "BrowserAttachState",
    "BrowserSnapshot",
    "Command",
    "ClientTerminalSize",
    "ClientSnapshot",
    "Cursor",
    "Document",
    "ExactCommand",
    "ExternalMachineSpecifier",
    "FrontendProjectionSnapshot",
    "JsonObject",
    "KeyInput",
    "LayoutColumn",
    "LayoutDocument",
    "LayoutLeaf",
    "LayoutNode",
    "LayoutSplit",
    "LayoutStack",
    "LayoutViewport",
    "MachineSnapshot",
    "MouseInput",
    "MutationResult",
    "NotificationSnapshot",
    "PairingRequestSnapshot",
    "PairingCode",
    "PaneSnapshot",
    "PixelSize",
    "ProviderActionSnapshot",
    "ProviderActionValue",
    "ProviderActionField",
    "ProviderCredential",
    "ProviderNoticeKnown",
    "ProviderNoticeItem",
    "ProviderNoticeSnapshot",
    "ProviderScopeSnapshot",
    "ResourceChange",
    "ResourceDelete",
    "ResourceEntitySnapshot",
    "ResourceKind",
    "ResourceSnapshot",
    "ResourceUpsert",
    "RendererGrant",
    "RenderCursor",
    "RenderPatch",
    "RenderRow",
    "RenderRun",
    "RenderScroll",
    "RenderSnapshot",
    "ScreenSnapshot",
    "SessionSnapshot",
    "SessionSnapshotItem",
    "SessionDelta",
    "SessionEvent",
    "ShellCommand",
    "SidebarAttachItem",
    "SidebarAttachPatch",
    "SidebarAttachScroll",
    "SidebarAttachSnapshot",
    "SidebarViewSnapshot",
    "Size",
    "Snapshot",
    "StreamEnd",
    "StreamItem",
    "TabSnapshot",
    "TerminalSnapshot",
    "TerminalAttachItem",
    "TerminalAttachPatch",
    "TerminalAttachScroll",
    "TerminalAttachSnapshot",
    "Unknown",
    "WorkspaceSnapshot",
    "exact",
    "shell",
    "shell_executable",
]
