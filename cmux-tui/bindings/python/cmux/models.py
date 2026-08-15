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
IdT = TypeVar("IdT", bound=ResourceId)
ValueT = TypeVar("ValueT")
ItemT = TypeVar("ItemT")


@dataclass(frozen=True)
class Snapshot(Generic[IdT]):
    id: IdT


@dataclass(frozen=True)
class MachineSnapshot(Snapshot[MachineId]):
    name: str
    origin: Literal["local"]
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
class TerminalExitCode:
    kind: Literal["exit"]
    code: int


@dataclass(frozen=True)
class TerminalExitSignal:
    kind: Literal["signal"]
    signal: int
    core_dumped: bool


@dataclass(frozen=True)
class TerminalExitUnknown:
    kind: Literal["unknown"]
    reason: str


TerminalExitOutcome = Union[
    TerminalExitCode,
    TerminalExitSignal,
    TerminalExitUnknown,
]


@dataclass(frozen=True)
class TerminalExit:
    outcome: TerminalExitOutcome
    exited_at: str
    revision: str


TerminalLifecycle = Literal["launching", "running", "exited"]


@dataclass(frozen=True)
class TerminalSnapshot(Snapshot[TerminalId]):
    tab_ids: Tuple[TabId, ...]
    title: str
    cols: int
    rows: int
    running: bool
    lifecycle: TerminalLifecycle
    cwd: Optional[str] = None
    exit: Optional[TerminalExit] = None
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
        if not isinstance(value, str):
            raise TypeError("pairing code must be a string")
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
    frontend_id: str
    window_id: str
    generation: str
    projection: Any
    projection_revision: str
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class SidebarViewSnapshot(Snapshot[SidebarViewId]):
    session_id: SessionId
    cols: int
    rows: int
    running: bool
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
class CreationResolution(Generic[ValueT]):
    correlation_key: str
    state: Literal["pending", "created", "not_applied", "indeterminate"]
    recovery: Literal[
        "retry_same_idempotency_key",
        "retry_new_idempotency_key",
        "wait",
        "none",
        "do_not_retry",
    ]
    operation: Optional[str] = None
    idempotency_key: Optional[str] = None
    created_path: Optional[ValueT] = None
    generation: Optional[str] = None
    revision: Optional[str] = None


MutationReceipt = MutationResult[None]


@dataclass(frozen=True)
class PingResult:
    alive: bool
    cursor: Cursor


@dataclass(frozen=True)
class ShutdownResult:
    accepted: bool


@dataclass(frozen=True)
class ReloadConfigResult:
    reloaded: bool
    warnings: Tuple[str, ...]


@dataclass(frozen=True)
class TerminalDefaultsSnapshot:
    foreground: Optional[str] = None
    background: Optional[str] = None
    cursor: Optional[str] = None
    selection_background: Optional[str] = None
    selection_foreground: Optional[str] = None
    cursor_style: Optional[Literal["block", "bar", "underline"]] = None
    cursor_blink: Optional[bool] = None
    palette: Optional[Mapping[str, str]] = None


@dataclass(frozen=True)
class TerminalScreenResult:
    text: str
    cols: int
    rows: int
    cursor_row: int
    cursor_col: int
    cursor_visible: bool
    extra: JsonObject = field(default_factory=dict)


@dataclass(frozen=True)
class TerminalStateResult:
    state: bytes
    cols: int
    rows: int


@dataclass(frozen=True)
class TerminalHistoryResult:
    start: str
    next: Optional[str]
    rows: Tuple["RenderRow", ...]


@dataclass(frozen=True)
class TerminalWaitResult:
    matched: bool
    text: str


@dataclass(frozen=True)
class TerminalWaitExitPending:
    state: Literal["pending"]
    terminal_id: TerminalId
    lifecycle: Literal["launching", "running"]
    revision: str


@dataclass(frozen=True)
class TerminalWaitExitExited:
    state: Literal["exited"]
    terminal_id: TerminalId
    lifecycle: Literal["exited"]
    outcome: TerminalExitOutcome
    exited_at: str
    revision: str


TerminalWaitExitResult = Union[
    TerminalWaitExitPending,
    TerminalWaitExitExited,
]

@dataclass(frozen=True)
class TerminalCopyResult:
    mode: Literal["screen", "selection", "scrollback"]
    text: str


@dataclass(frozen=True)
class ProcessInfoResult:
    pid: int
    executable: Optional[str]
    argv: Tuple[str, ...]
    cwd: Optional[str]
    children: Tuple[int, ...]


@dataclass(frozen=True)
class ViewerResizeResult:
    accepted: bool
    size: "Size"
    outcome: "ViewAttachmentOutcome"


@dataclass(frozen=True)
class BrowserViewerResizeResult:
    accepted: bool
    size: "PixelSize"
    outcome: "ViewAttachmentOutcome"


ViewAttachmentOutcome = Literal["applied", "passive", "superseded"]


@dataclass(frozen=True)
class ViewerReleaseResult:
    outcome: ViewAttachmentOutcome


@dataclass(frozen=True)
class CellPixelsResult:
    width_px: int
    height_px: int
    resized_terminals: Tuple[TerminalId, ...]
    failures: Mapping[str, str]


@dataclass(frozen=True)
class PairingResolutionResult:
    pairing_request: PairingRequestSnapshot


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

JournalClass = Literal["state", "observation", "effect", "checkpoint"]
JournalReplayPolicy = Literal["required", "advisory", "never"]
JournalSensitivity = Literal["public", "metadata", "sensitive", "secret"]


@dataclass(frozen=True)
class JournalProducer:
    kind: str
    id: str


@dataclass(frozen=True)
class JournalAuthority:
    principal_id: str
    lease_id: str
    generation: str
    role: str


@dataclass(frozen=True)
class JournalSubject:
    kind: str
    id: str


@dataclass(frozen=True)
class SessionJournalRecord:
    sequence: str
    event_id: str
    schema_version: int
    kind: str
    class_: JournalClass
    replay: JournalReplayPolicy
    occurred_at_ms: str
    committed_at_ms: str
    producer: JournalProducer
    authority: Optional[JournalAuthority]
    causation_id: Optional[str]
    correlation_id: Optional[str]
    causation_depth: int
    subjects: Tuple[JournalSubject, ...]
    sensitivity: JournalSensitivity
    payload: Any
    resource_revision: Optional[str]
    previous_resource_revision: Optional[str]


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
    pointer_frame_seq: Optional[int]


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


__all__ = [
    "AgentSnapshot",
    "BrowserAttachFrame",
    "BrowserAttachItem",
    "BrowserAttachSnapshot",
    "BrowserAttachState",
    "BrowserSnapshot",
    "BrowserViewerResizeResult",
    "CellPixelsResult",
    "Command",
    "ClientTerminalSize",
    "ClientSnapshot",
    "CreationResolution",
    "Cursor",
    "Document",
    "ExactCommand",
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
    "MutationReceipt",
    "NotificationSnapshot",
    "PairingRequestSnapshot",
    "PairingResolutionResult",
    "PairingCode",
    "PaneSnapshot",
    "PixelSize",
    "PingResult",
    "ProcessInfoResult",
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
    "ReloadConfigResult",
    "ScreenSnapshot",
    "SessionSnapshot",
    "ShutdownResult",
    "SessionSnapshotItem",
    "SessionDelta",
    "SessionEvent",
    "JournalAuthority",
    "JournalClass",
    "JournalProducer",
    "JournalReplayPolicy",
    "JournalSensitivity",
    "JournalSubject",
    "SessionJournalRecord",
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
    "TerminalCopyResult",
    "TerminalDefaultsSnapshot",
    "TerminalExit",
    "TerminalExitCode",
    "TerminalExitOutcome",
    "TerminalExitSignal",
    "TerminalExitUnknown",
    "TerminalHistoryResult",
    "TerminalLifecycle",
    "TerminalScreenResult",
    "TerminalStateResult",
    "TerminalWaitExitExited",
    "TerminalWaitExitPending",
    "TerminalWaitExitResult",
    "TerminalWaitResult",
    "TerminalAttachItem",
    "TerminalAttachPatch",
    "TerminalAttachScroll",
    "TerminalAttachSnapshot",
    "Unknown",
    "ViewerResizeResult",
    "ViewerReleaseResult",
    "ViewAttachmentOutcome",
    "WorkspaceSnapshot",
    "exact",
    "shell",
    "shell_executable",
]
