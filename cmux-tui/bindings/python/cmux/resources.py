from __future__ import annotations

import secrets
import math
import base64
import binascii
import threading
from dataclasses import asdict, dataclass, fields
from typing import (
    Any,
    Callable,
    Dict,
    Generic,
    List,
    Literal,
    Mapping,
    Optional,
    Sequence,
    Type,
    TypeVar,
    Union,
)

from ._operations import Operation, Operations
from ._protocol import ProtocolConnection, ResourceStream
from .client_defaults import default_socket_path, env_socket_path
from .errors import (
    CancelledError,
    CmuxConnectionError,
    MutationTransportError,
    ProtocolError,
    TimeoutError,
)
from .ids import (
    AgentId,
    BrowserId,
    ConnectedClientId,
    IdT,
    MachineId,
    NotificationId,
    PairingRequestId,
    PaneId,
    ProjectionId,
    ResourceId,
    ScreenId,
    Selector,
    SelectorInput,
    SessionId,
    SidebarViewId,
    SplitId,
    TabId,
    TerminalId,
    WorkspaceId,
    encode_selector,
)
from .models import (
    AgentSnapshot,
    BrowserAttachFrame,
    BrowserAttachItem,
    BrowserAttachSnapshot,
    BrowserAttachState,
    BrowserSnapshot,
    BrowserViewerResizeResult,
    CellPixelsResult,
    ClientTerminalSize,
    ClientSnapshot,
    CreationResolution,
    Cursor,
    ExactCommand,
    FrontendProjectionSnapshot,
    JsonObject,
    LayoutColumn,
    LayoutDocument,
    LayoutLeaf,
    LayoutNode,
    LayoutSplit,
    LayoutStack,
    LayoutViewport,
    MachineSnapshot,
    MutationReceipt,
    MutationResult,
    NotificationSnapshot,
    PairingCode,
    PairingRequestSnapshot,
    PairingResolutionResult,
    PaneSnapshot,
    PingResult,
    ProcessInfoResult,
    ResourceChange,
    ResourceDelete,
    ResourceEntitySnapshot,
    ResourceKind,
    ResourceSnapshot,
    ResourceUpsert,
    RendererGrant,
    RenderCursor,
    RenderPatch,
    RenderRow,
    RenderRun,
    RenderScroll,
    RenderSnapshot,
    ReloadConfigResult,
    ScreenSnapshot,
    SessionDelta,
    SessionEvent,
    JournalAuthority,
    JournalProducer,
    JournalSubject,
    SessionJournalRecord,
    SessionSnapshotItem,
    SessionSnapshot,
    ShellCommand,
    ShutdownResult,
    SidebarAttachItem,
    SidebarAttachPatch,
    SidebarAttachScroll,
    SidebarAttachSnapshot,
    SidebarViewSnapshot,
    Snapshot,
    TabSnapshot,
    TerminalAttachItem,
    TerminalAttachPatch,
    TerminalAttachScroll,
    TerminalAttachSnapshot,
    TerminalCopyResult,
    TerminalDefaultsSnapshot,
    TerminalExit,
    TerminalExitCode,
    TerminalExitOutcome,
    TerminalExitSignal,
    TerminalExitUnknown,
    TerminalHistoryResult,
    TerminalLifecycle,
    TerminalScreenResult,
    TerminalSnapshot,
    TerminalStateResult,
    TerminalWaitExitExited,
    TerminalWaitExitPending,
    TerminalWaitExitResult,
    TerminalWaitResult,
    Size,
    PixelSize,
    Unknown,
    ViewAttachmentOutcome,
    ViewerReleaseResult,
    ViewerResizeResult,
    WorkspaceSnapshot,
)
from .options import (
    AgentReportOptions,
    BrowserAttachOptions,
    BrowserMouseOptions,
    BrowserViewerSizeOptions,
    CancellationToken,
    CreateBrowserOptions,
    CreatePaneOptions,
    CreateScreenOptions,
    CreateTerminalOptions,
    CreateWorkspaceOptions,
    Direction,
    KeyInputOptions,
    LayoutApplyOptions,
    NotificationOptions,
    RequestOptions,
    RunOptions,
    SessionEventsOptions,
    SessionJournalOptions,
    SidebarEnsureOptions,
    SidebarInputOptions,
    SidebarResizeOptions,
    SplitPaneOptions,
    TerminalAttachOptions,
    TerminalHistoryOptions,
    TerminalMouseOptions,
    TerminalWaitOptions,
    ViewerSizeOptions,
)


SnapshotT = TypeVar("SnapshotT", bound=Snapshot[Any])
ValueT = TypeVar("ValueT")
StreamValueT = TypeVar("StreamValueT")
LocalExecutor = Callable[[str, Mapping[str, Any]], Any]
RandomHex128 = Callable[[], str]
_UNSET = object()


@dataclass(frozen=True)
class _RequestContext:
    options: RequestOptions
    cancel_event: Optional["_CancellationSignal"]


class _CancellationSignal:
    def __init__(
        self,
        token: Optional[CancellationToken],
        task_event: Optional[threading.Event],
    ) -> None:
        self._token = token
        self._task_event = task_event

    def is_set(self) -> bool:
        return (
            self._token is not None
            and self._token.is_cancelled
        ) or (
            self._task_event is not None
            and self._task_event.is_set()
        )


def _selector(value: SelectorInput[IdT], expected: Type[IdT]) -> Selector[IdT]:
    if isinstance(value, expected):
        return Selector.by_id(value)
    if isinstance(value, Selector):
        encode_selector(value, expected)
        return value
    raise TypeError(f"selector requires {expected.__name__} or Selector")


def _options(value: object) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for item in fields(value):
        field_value = getattr(value, item.name)
        if field_value is None:
            continue
        name = {
            "columns": "cols",
            "command": None,
        }.get(item.name, item.name)
        if isinstance(field_value, (ExactCommand, ShellCommand)):
            result.update(field_value.to_params())
        elif isinstance(field_value, Cursor):
            result[item.name] = asdict(field_value)
        elif item.name == "keys":
            result[item.name] = [_plain(entry) for entry in field_value]
        elif item.name == "mouse":
            result[item.name] = _plain(field_value)
        elif name is not None:
            result[name] = _plain(field_value)
    return result


def _journal_options(value: SessionJournalOptions) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    if value.cursor is not None:
        result["cursor"] = asdict(value.cursor)
    if value.start is not None:
        result["start"] = value.start
    if value.follow is not None:
        result["follow"] = value.follow
    if value.filter is None:
        return result
    filter_value: Dict[str, Any] = {}
    if value.filter.kinds is not None:
        filter_value["kinds"] = list(value.filter.kinds)
    if value.filter.classes is not None:
        filter_value["classes"] = list(value.filter.classes)
    if value.filter.subjects is not None:
        filter_value["subjects"] = [
            {
                key: item
                for key, item in (("kind", subject.kind), ("id", subject.id))
                if item is not None
            }
            for subject in value.filter.subjects
        ]
    if value.filter.max_sensitivity is not None:
        filter_value["max_sensitivity"] = value.filter.max_sensitivity
    if value.filter.regex is not None:
        filter_value["regex"] = asdict(value.filter.regex)
    if filter_value:
        result["filter"] = filter_value
    return result


def _plain(value: Any) -> Any:
    if isinstance(value, ResourceId):
        return str(value)
    if isinstance(value, Selector):
        return value.encode()
    if isinstance(value, (ExactCommand, ShellCommand)):
        return value.to_params()
    if hasattr(value, "__dataclass_fields__"):
        return {
            key: _plain(item)
            for key, item in asdict(value).items()
            if item is not None
        }
    if isinstance(value, Mapping):
        return {str(key): _plain(item) for key, item in value.items()}
    if isinstance(value, (tuple, list)):
        return [_plain(item) for item in value]
    return value


def _decimal_param(value: Any, label: str) -> str:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < 0
        or value > 18_446_744_073_709_551_615
    ):
        raise ValueError(f"{label} must be an unsigned 64-bit integer")
    return str(value)


def _mapping(value: Any, label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ProtocolError(f"{label} must be an object")
    return value


def _unwrap_resource(value: Any, names: Sequence[str]) -> Mapping[str, Any]:
    del names
    return _mapping(value, "resource result")


def _optional_id(
    payload: Mapping[str, Any],
    keys: Sequence[str],
    expected: Type[IdT],
) -> Optional[IdT]:
    for key in keys:
        value = payload.get(key)
        if value is not None:
            try:
                return expected(value)
            except (TypeError, ValueError) as error:
                raise ProtocolError(f"invalid {key}: {error}") from error
    return None


def _required_id(
    payload: Mapping[str, Any],
    keys: Sequence[str],
    expected: Type[IdT],
) -> IdT:
    value = _optional_id(payload, keys, expected)
    if value is None:
        raise ProtocolError(f"resource result omitted {'/'.join(keys)} ID")
    return value


def _required_string(payload: Mapping[str, Any], key: str) -> str:
    value = payload.get(key)
    if not isinstance(value, str):
        raise ProtocolError(f"resource result omitted required string {key}")
    return value


def _optional_string(payload: Mapping[str, Any], key: str) -> Optional[str]:
    value = payload.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise ProtocolError(f"resource field {key} must be a string")
    return value


def _required_bool(payload: Mapping[str, Any], key: str) -> bool:
    value = payload.get(key)
    if not isinstance(value, bool):
        raise ProtocolError(f"resource result omitted required boolean {key}")
    return value


def _required_int(payload: Mapping[str, Any], key: str) -> int:
    value = payload.get(key)
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < 0
        or value > 4_294_967_295
    ):
        raise ProtocolError(
            f"resource result omitted required unsigned integer {key}"
        )
    return value


def _strict_object(
    payload: Mapping[str, Any],
    allowed: Sequence[str],
    label: str,
) -> None:
    unknown = set(payload).difference(allowed)
    if unknown:
        raise ProtocolError(
            f"{label} contains unknown field {sorted(unknown)[0]!r}"
        )


def _snapshot_fields(
    payload: Mapping[str, Any],
    expected: Type[IdT],
    fields: Sequence[str],
) -> Dict[str, Any]:
    _strict_object(payload, ("id", "extra", *fields), "resource snapshot")
    declared_extra = payload.get("extra", {})
    if not isinstance(declared_extra, Mapping):
        raise ProtocolError("resource extra must be an object")
    return {
        "id": _required_id(payload, ("id",), expected),
        "extra": dict(declared_extra),
    }


def _required_nullable_string(
    payload: Mapping[str, Any],
    key: str,
) -> Optional[str]:
    if key not in payload:
        raise ProtocolError(f"resource result omitted required field {key}")
    value = payload[key]
    if value is not None and not isinstance(value, str):
        raise ProtocolError(f"resource field {key} must be a string or null")
    return value


def _optional_present_string(
    payload: Mapping[str, Any],
    key: str,
) -> Optional[str]:
    if key not in payload:
        return None
    return _required_string(payload, key)


def _required_decimal(payload: Mapping[str, Any], key: str) -> str:
    value = _required_string(payload, key)
    if (
        not value
        or any(character not in "0123456789" for character in value)
        or (len(value) > 1 and value.startswith("0"))
        or int(value) > 18_446_744_073_709_551_615
    ):
        raise ProtocolError(f"resource field {key} must be a uint64 decimal string")
    return value


def _required_nullable_decimal(
    payload: Mapping[str, Any], key: str
) -> Optional[str]:
    if key not in payload:
        raise ProtocolError(f"resource result omitted required field {key}")
    if payload[key] is None:
        return None
    return _required_decimal(payload, key)


def _required_nullable_decimal_int(
    payload: Mapping[str, Any],
    key: str,
) -> Optional[int]:
    if key not in payload:
        raise ProtocolError(f"resource result omitted required field {key}")
    if payload[key] is None:
        return None
    return int(_required_decimal(payload, key))


def _required_generation(payload: Mapping[str, Any], key: str) -> str:
    value = _required_string(payload, key)
    if not 1 <= len(value) <= 128:
        raise ProtocolError(
            f"resource field {key} must contain 1 to 128 characters"
        )
    return value


def _required_enum(
    payload: Mapping[str, Any],
    key: str,
    values: Sequence[str],
) -> str:
    value = _required_string(payload, key)
    if value not in values:
        raise ProtocolError(f"resource field {key} has invalid value {value!r}")
    return value


def _optional_resource_id(
    payload: Mapping[str, Any],
    key: str,
    expected: Type[IdT],
) -> Optional[IdT]:
    if key not in payload:
        return None
    return _required_id(payload, (key,), expected)


def _required_number(payload: Mapping[str, Any], key: str) -> float:
    value = payload.get(key)
    if (
        not isinstance(value, (int, float))
        or isinstance(value, bool)
        or not math.isfinite(value)
    ):
        raise ProtocolError(f"resource result omitted required number {key}")
    return float(value)


def _required_positive_uint16(payload: Mapping[str, Any], key: str) -> int:
    value = _required_int(payload, key)
    if value < 1 or value > 65_535:
        raise ProtocolError(f"resource field {key} must be between 1 and 65535")
    return value


def _required_uint16(payload: Mapping[str, Any], key: str) -> int:
    value = _required_int(payload, key)
    if value > 65_535:
        raise ProtocolError(f"resource field {key} must be a uint16")
    return value


def _required_positive_uint32(payload: Mapping[str, Any], key: str) -> int:
    value = _required_int(payload, key)
    if value < 1:
        raise ProtocolError(f"resource field {key} must be positive")
    return value


def _required_int32(payload: Mapping[str, Any], key: str) -> int:
    value = payload.get(key)
    if (
        not isinstance(value, int)
        or isinstance(value, bool)
        or value < -2_147_483_648
        or value > 2_147_483_647
    ):
        raise ProtocolError(f"resource field {key} must be an int32")
    return value


def _size(value: Any) -> Size:
    payload = _mapping(value, "size")
    _strict_object(payload, ("cols", "rows"), "size")
    return Size(
        _required_positive_uint16(payload, "cols"),
        _required_positive_uint16(payload, "rows"),
    )


def _layout_node(value: Any) -> LayoutNode:
    payload = _mapping(value, "layout node")
    kind = _required_string(payload, "kind")
    if kind == "leaf":
        _strict_object(
            payload,
            ("kind", "pane_id", "tab_ids", "active_tab_id"),
            "layout leaf",
        )
        tab_values = payload.get("tab_ids")
        if not isinstance(tab_values, list):
            raise ProtocolError("layout leaf tab_ids must be an array")
        return LayoutLeaf(
            "leaf",
            _required_id(payload, ("pane_id",), PaneId),
            tuple(
                _required_id({"id": item}, ("id",), TabId)
                for item in tab_values
            ),
            _optional_resource_id(payload, "active_tab_id", TabId),
        )
    if kind == "split":
        _strict_object(
            payload,
            ("kind", "split_id", "direction", "ratio", "first", "second"),
            "layout split",
        )
        direction = _required_enum(
            payload,
            "direction",
            ("horizontal", "vertical"),
        )
        ratio = _required_number(payload, "ratio")
        if not 0 < ratio < 1:
            raise ProtocolError("layout split ratio must be greater than 0 and less than 1")
        return LayoutSplit(
            "split",
            _required_id(payload, ("split_id",), SplitId),
            direction,  # type: ignore[arg-type]
            ratio,
            _layout_node(payload.get("first")),
            _layout_node(payload.get("second")),
        )
    if kind == "stack":
        _strict_object(
            payload,
            ("kind", "pane_ids", "expanded_pane_id"),
            "layout stack",
        )
        pane_values = payload.get("pane_ids")
        if not isinstance(pane_values, list) or not pane_values:
            raise ProtocolError("layout stack pane_ids must be a non-empty array")
        pane_ids = tuple(
            _required_id({"id": item}, ("id",), PaneId)
            for item in pane_values
        )
        expanded_pane_id = _required_id(
            payload,
            ("expanded_pane_id",),
            PaneId,
        )
        if expanded_pane_id not in pane_ids:
            raise ProtocolError("layout stack expanded_pane_id must be in pane_ids")
        return LayoutStack(
            "stack",
            pane_ids,
            expanded_pane_id,
        )
    if kind == "viewport":
        _strict_object(
            payload,
            ("kind", "base_width", "columns"),
            "layout viewport",
        )
        column_values = payload.get("columns")
        if not isinstance(column_values, list) or not column_values:
            raise ProtocolError("layout viewport columns must be a non-empty array")
        columns: List[LayoutColumn] = []
        for value in column_values:
            column = _mapping(value, "layout column")
            _strict_object(
                column,
                ("column_id", "width", "root"),
                "layout column",
            )
            width = _required_number(column, "width")
            if not 0.1 <= width <= 1:
                raise ProtocolError(
                    "layout column width must be between 0.1 and 1"
                )
            columns.append(
                LayoutColumn(
                    _required_id(column, ("column_id",), SplitId),
                    width,
                    _layout_node(column.get("root")),
                )
            )
        base_width = _required_number(payload, "base_width")
        if not 0.1 <= base_width <= 1:
            raise ProtocolError(
                "layout viewport base_width must be between 0.1 and 1"
            )
        return LayoutViewport(
            "viewport",
            base_width,
            tuple(columns),
        )
    raise ProtocolError(f"unknown layout node kind {kind!r}")


def _layout_document(value: Any) -> LayoutDocument:
    payload = _mapping(value, "layout document")
    _strict_object(
        payload,
        (
            "version",
            "screen_id",
            "active_pane_id",
            "zoomed_pane_id",
            "root",
            "extra",
        ),
        "layout document",
    )
    extra = payload.get("extra", {})
    if not isinstance(extra, Mapping):
        raise ProtocolError("layout document extra must be an object")
    zoomed = payload.get("zoomed_pane_id")
    if zoomed is not None:
        zoomed = _required_id(payload, ("zoomed_pane_id",), PaneId)
    elif "zoomed_pane_id" not in payload:
        raise ProtocolError("layout document omitted zoomed_pane_id")
    return LayoutDocument(
        _required_id(payload, ("screen_id",), ScreenId),
        _required_id(payload, ("active_pane_id",), PaneId),
        zoomed,
        _layout_node(payload.get("root")),
        _required_int(payload, "version"),
        dict(extra),
    )


def _machine_snapshot(value: Any) -> MachineSnapshot:
    payload = _unwrap_resource(value, ("machine",))
    fields = (
        "name",
        "origin",
        "status",
        "connectable",
        "deleted",
        "recoverable",
    )
    origin = _required_enum(payload, "origin", ("local",))
    status = _required_enum(
        payload,
        "status",
        ("running", "connecting", "sleeping", "stopped", "unavailable"),
    )
    return MachineSnapshot(
        **_snapshot_fields(payload, MachineId, fields),
        name=_required_string(payload, "name"),
        origin=origin,  # type: ignore[arg-type]
        status=status,  # type: ignore[arg-type]
        connectable=_required_bool(payload, "connectable"),
        deleted=_required_bool(payload, "deleted"),
        recoverable=_required_bool(payload, "recoverable"),
    )


def _session_snapshot(value: Any) -> SessionSnapshot:
    payload = _unwrap_resource(value, ("session",))
    return SessionSnapshot(
        **_snapshot_fields(
            payload,
            SessionId,
            ("machine_id", "name", "generation", "revision", "connected"),
        ),
        machine_id=_required_id(payload, ("machine_id",), MachineId),
        name=_optional_present_string(payload, "name"),
        generation=_required_generation(payload, "generation"),
        revision=_required_decimal(payload, "revision"),
        connected=_required_bool(payload, "connected"),
    )


def _workspace_snapshot(value: Any) -> WorkspaceSnapshot:
    payload = _unwrap_resource(value, ("workspace",))
    return WorkspaceSnapshot(
        **_snapshot_fields(
            payload,
            WorkspaceId,
            ("session_id", "name", "index", "focused"),
        ),
        session_id=_required_id(payload, ("session_id",), SessionId),
        name=_required_string(payload, "name"),
        index=_required_int(payload, "index"),
        focused=_required_bool(payload, "focused"),
    )


def _screen_snapshot(value: Any) -> ScreenSnapshot:
    payload = _unwrap_resource(value, ("screen",))
    return ScreenSnapshot(
        **_snapshot_fields(
            payload,
            ScreenId,
            ("workspace_id", "name", "index", "focused", "layout"),
        ),
        workspace_id=_required_id(payload, ("workspace_id",), WorkspaceId),
        name=_required_nullable_string(payload, "name"),
        index=_required_int(payload, "index"),
        focused=_required_bool(payload, "focused"),
        layout=_layout_document(payload.get("layout")),
    )


def _pane_snapshot(value: Any) -> PaneSnapshot:
    payload = _unwrap_resource(value, ("pane",))
    return PaneSnapshot(
        **_snapshot_fields(
            payload,
            PaneId,
            ("screen_id", "name", "focused", "zoomed"),
        ),
        screen_id=_required_id(payload, ("screen_id",), ScreenId),
        name=_required_nullable_string(payload, "name"),
        focused=_required_bool(payload, "focused"),
        zoomed=_required_bool(payload, "zoomed"),
    )


def _tab_snapshot(value: Any) -> TabSnapshot:
    payload = _unwrap_resource(value, ("tab",))
    content_kind = _required_string(payload, "content_kind")
    if content_kind == "terminal":
        content_id: Union[TerminalId, BrowserId] = _required_id(
            payload, ("content_id",), TerminalId
        )
    elif content_kind == "browser":
        content_id = _required_id(payload, ("content_id",), BrowserId)
    else:
        raise ProtocolError("tab content_kind must be terminal or browser")
    return TabSnapshot(
        **_snapshot_fields(
            payload,
            TabId,
            (
                "pane_id",
                "name",
                "index",
                "focused",
                "content_kind",
                "content_id",
            ),
        ),
        pane_id=_required_id(payload, ("pane_id",), PaneId),
        name=_required_nullable_string(payload, "name"),
        index=_required_int(payload, "index"),
        focused=_required_bool(payload, "focused"),
        content_kind=content_kind,  # type: ignore[arg-type]
        content_id=content_id,
    )


def _terminal_snapshot(value: Any) -> TerminalSnapshot:
    payload = _unwrap_resource(value, ("terminal",))
    has_tab_id = "tab_id" in payload
    has_tab_ids = "tab_ids" in payload
    if not has_tab_id and not has_tab_ids:
        raise ProtocolError("terminal snapshot requires tab_ids or tab_id")
    legacy_tab_id = None
    if has_tab_id and payload["tab_id"] is not None:
        legacy_tab_id = _required_id(payload, ("tab_id",), TabId)
    if has_tab_ids:
        raw_tab_ids = payload["tab_ids"]
        if not isinstance(raw_tab_ids, list):
            raise ProtocolError("terminal tab_ids must be an array")
        tab_ids = tuple(
            _required_id({"id": item}, ("id",), TabId)
            for item in raw_tab_ids
        )
    else:
        tab_ids = () if legacy_tab_id is None else (legacy_tab_id,)
    if has_tab_id and legacy_tab_id != (tab_ids[0] if tab_ids else None):
        raise ProtocolError("terminal tab_id must be the first tab_ids item")
    lifecycle = _required_enum(
        payload,
        "lifecycle",
        ("launching", "running", "exited"),
    )
    running = _required_bool(payload, "running")
    exit_record = None
    if "exit" in payload:
        if payload["exit"] is None:
            raise ProtocolError("terminal exit must be an object when present")
        exit_record = _terminal_exit(payload["exit"])
    if running != (lifecycle == "running"):
        raise ProtocolError(
            "terminal running must be true exactly when lifecycle is running"
        )
    if (exit_record is not None) != (lifecycle == "exited"):
        raise ProtocolError(
            "terminal exit must be present exactly when lifecycle is exited"
        )
    return TerminalSnapshot(
        **_snapshot_fields(
            payload,
            TerminalId,
            (
                "tab_id",
                "tab_ids",
                "title",
                "cwd",
                "cols",
                "rows",
                "running",
                "lifecycle",
                "exit",
            ),
        ),
        tab_ids=tab_ids,
        title=_required_string(payload, "title"),
        cwd=_optional_present_string(payload, "cwd"),
        cols=_required_positive_uint16(payload, "cols"),
        rows=_required_positive_uint16(payload, "rows"),
        running=running,
        lifecycle=lifecycle,  # type: ignore[arg-type]
        exit=exit_record,
    )


def _browser_snapshot(value: Any) -> BrowserSnapshot:
    payload = _unwrap_resource(value, ("browser",))
    return BrowserSnapshot(
        **_snapshot_fields(
            payload,
            BrowserId,
            (
                "tab_id",
                "url",
                "title",
                "loading",
                "source",
                "status",
                "error",
                "frames_stalled",
                "size",
            ),
        ),
        tab_id=_required_id(payload, ("tab_id",), TabId),
        url=_required_string(payload, "url"),
        title=_required_string(payload, "title"),
        loading=_required_bool(payload, "loading"),
        source=_required_enum(
            payload,
            "source",
            ("external", "launched"),
        ),  # type: ignore[arg-type]
        status=_required_enum(
            payload,
            "status",
            ("starting", "live", "failed"),
        ),  # type: ignore[arg-type]
        error=_required_nullable_string(payload, "error"),
        frames_stalled=_required_bool(payload, "frames_stalled"),
        size=_size(payload.get("size")),
    )


def _connected_client_snapshot(value: Any) -> ClientSnapshot:
    payload = _unwrap_resource(value, ("client",))
    attached = payload.get("attached_terminal_ids")
    if not isinstance(attached, list):
        raise ProtocolError("client attached_terminal_ids must be an array")
    sizes = payload.get("sizes")
    if not isinstance(sizes, list):
        raise ProtocolError("client sizes must be an array")
    transport = _required_enum(payload, "transport", ("unix", "websocket"))
    return ClientSnapshot(
        **_snapshot_fields(
            payload,
            ConnectedClientId,
            (
                "session_id",
                "name",
                "client_kind",
                "transport",
                "connected_seconds",
                "attached_terminal_ids",
                "sizes",
                "self",
            ),
        ),
        session_id=_required_id(payload, ("session_id",), SessionId),
        name=_required_nullable_string(payload, "name"),
        client_kind=_required_nullable_string(payload, "client_kind"),
        transport=transport,  # type: ignore[arg-type]
        connected_seconds=_required_decimal(payload, "connected_seconds"),
        attached_terminal_ids=tuple(
            _required_id({"id": item}, ("id",), TerminalId)
            for item in attached
        ),
        sizes=tuple(_client_terminal_size(value) for value in sizes),
        self=_required_bool(payload, "self"),
    )


def _client_terminal_size(value: Any) -> ClientTerminalSize:
    payload = _mapping(value, "client terminal size")
    _strict_object(
        payload,
        ("terminal_id", "cols", "rows", "participating"),
        "client terminal size",
    )
    if "cols" not in payload or "rows" not in payload:
        raise ProtocolError("client terminal size omitted cols or rows")
    cols = payload.get("cols")
    rows = payload.get("rows")
    if cols is not None:
        cols = _required_positive_uint16(payload, "cols")
    if rows is not None:
        rows = _required_positive_uint16(payload, "rows")
    return ClientTerminalSize(
        _required_id(payload, ("terminal_id",), TerminalId),
        cols,
        rows,
        _required_bool(payload, "participating"),
    )


def _aux_snapshot(
    value: Any,
    name: str,
    id_type: Type[IdT],
    snapshot_type: Type[SnapshotT],
    *,
    parent_key: Optional[str] = None,
    parent_type: Optional[Type[ResourceId]] = None,
) -> SnapshotT:
    payload = _unwrap_resource(value, (name,))
    fields_by_type: Dict[Type[Any], Sequence[str]] = {
        PairingRequestSnapshot: (
            "session_id",
            "peer",
            "code",
            "expires_in_seconds",
            "status",
        ),
        FrontendProjectionSnapshot: (
            "session_id",
            "frontend_id",
            "window_id",
            "generation",
            "projection",
            "projection_revision",
        ),
        NotificationSnapshot: (
            "session_id",
            "title",
            "body",
            "level",
            "terminal_id",
            "created_at_ms",
            "unread",
        ),
        AgentSnapshot: (
            "session_id",
            "terminal_id",
            "state",
            "source",
            "updated_at_ms",
            "source_session",
        ),
        SidebarViewSnapshot: (
            "session_id",
            "cols",
            "rows",
            "running",
        ),
    }
    known = list(fields_by_type.get(snapshot_type, ()))
    if parent_key is not None and f"{parent_key}_id" not in known:
        known.append(f"{parent_key}_id")
    arguments = _snapshot_fields(payload, id_type, known)
    if snapshot_type is PairingRequestSnapshot:
        arguments.update(
            session_id=_required_id(payload, ("session_id",), SessionId),
            peer=_required_string(payload, "peer"),
            code=PairingCode(_required_string(payload, "code")),
            expires_in_seconds=_required_decimal(
                payload,
                "expires_in_seconds",
            ),
            status=_required_enum(
                payload,
                "status",
                ("pending", "accepted", "rejected"),
            ),
        )
    elif snapshot_type is FrontendProjectionSnapshot:
        arguments["session_id"] = _required_id(
            payload,
            ("session_id",),
            SessionId,
        )
        arguments["frontend_id"] = _required_string(payload, "frontend_id")
        arguments["window_id"] = _required_string(payload, "window_id")
        arguments["generation"] = _required_string(payload, "generation")
        if "projection" not in payload:
            raise ProtocolError("frontend projection omitted projection")
        arguments["projection"] = payload["projection"]
        arguments["projection_revision"] = _required_decimal(
            payload,
            "projection_revision",
        )
    elif snapshot_type is NotificationSnapshot:
        arguments.update(
            title=_required_string(payload, "title"),
            body=_required_string(payload, "body"),
            level=_required_enum(
                payload,
                "level",
                ("info", "warning", "error"),
            ),
            session_id=_required_id(payload, ("session_id",), SessionId),
            terminal_id=_optional_resource_id(payload, "terminal_id", TerminalId),
            created_at_ms=_required_decimal(payload, "created_at_ms"),
            unread=_required_bool(payload, "unread"),
        )
    elif snapshot_type is AgentSnapshot:
        arguments.update(
            terminal_id=_required_id(payload, ("terminal_id",), TerminalId),
            session_id=_required_id(payload, ("session_id",), SessionId),
            state=_required_enum(
                payload,
                "state",
                ("working", "blocked", "idle", "done", "unknown"),
            ),
            source=_required_enum(
                payload,
                "source",
                ("hook", "socket", "detected"),
            ),
            updated_at_ms=_required_decimal(payload, "updated_at_ms"),
            source_session=_required_nullable_string(
                payload,
                "source_session",
            ),
        )
    elif snapshot_type is SidebarViewSnapshot:
        arguments.update(
            session_id=_required_id(payload, ("session_id",), SessionId),
            cols=_required_positive_uint16(payload, "cols"),
            rows=_required_positive_uint16(payload, "rows"),
            running=_required_bool(payload, "running"),
        )
    return snapshot_type(**arguments)


def _list_payload(value: Any, key: str) -> List[Any]:
    if not isinstance(value, list):
        raise ProtocolError(f"{key} result must be an array")
    return value


def _pairing_resolution(value: Any) -> PairingResolutionResult:
    payload = _mapping(value, "pairing resolution")
    _strict_object(payload, ("pairing_request",), "pairing resolution")
    return PairingResolutionResult(
        _aux_snapshot(
            payload.get("pairing_request"),
            "pairing_request",
            PairingRequestId,
            PairingRequestSnapshot,
        )
    )


def _empty_result(value: Any) -> None:
    payload = _mapping(value, "empty result")
    _strict_object(payload, (), "empty result")
    return None


def _ping_result(value: Any) -> PingResult:
    payload = _mapping(value, "ping result")
    _strict_object(payload, ("alive", "cursor"), "ping result")
    return PingResult(
        _required_bool(payload, "alive"),
        _cursor(payload.get("cursor")),
    )


def _shutdown_result(value: Any) -> ShutdownResult:
    payload = _mapping(value, "shutdown result")
    _strict_object(payload, ("accepted",), "shutdown result")
    return ShutdownResult(_required_bool(payload, "accepted"))


def _reload_config_result(value: Any) -> ReloadConfigResult:
    payload = _mapping(value, "reload config result")
    _strict_object(payload, ("reloaded", "warnings"), "reload config result")
    warnings = payload.get("warnings")
    if not isinstance(warnings, list) or not all(
        isinstance(item, str) for item in warnings
    ):
        raise ProtocolError("reload config warnings must be an array of strings")
    return ReloadConfigResult(
        _required_bool(payload, "reloaded"),
        tuple(warnings),
    )


def _terminal_defaults_snapshot(value: Any) -> TerminalDefaultsSnapshot:
    payload = _mapping(value, "terminal defaults")
    allowed = (
        "foreground",
        "background",
        "cursor",
        "selection_background",
        "selection_foreground",
        "cursor_style",
        "cursor_blink",
        "palette",
    )
    _strict_object(payload, allowed, "terminal defaults")

    def optional_string(key: str) -> Optional[str]:
        if key not in payload or payload[key] is None:
            return None
        return _required_string(payload, key)

    cursor_style = optional_string("cursor_style")
    if cursor_style not in {None, "block", "bar", "underline"}:
        raise ProtocolError("terminal defaults cursor_style is invalid")
    cursor_blink = payload.get("cursor_blink")
    if cursor_blink is not None and not isinstance(cursor_blink, bool):
        raise ProtocolError("terminal defaults cursor_blink must be boolean or null")
    raw_palette = payload.get("palette")
    palette: Optional[Mapping[str, str]] = None
    if raw_palette is not None:
        if not isinstance(raw_palette, Mapping) or not all(
            isinstance(key, str) and isinstance(item, str)
            for key, item in raw_palette.items()
        ):
            raise ProtocolError("terminal defaults palette must map strings to strings")
        palette = dict(raw_palette)
    return TerminalDefaultsSnapshot(
        foreground=optional_string("foreground"),
        background=optional_string("background"),
        cursor=optional_string("cursor"),
        selection_background=optional_string("selection_background"),
        selection_foreground=optional_string("selection_foreground"),
        cursor_style=cursor_style,  # type: ignore[arg-type]
        cursor_blink=cursor_blink,
        palette=palette,
    )


def _terminal_screen_result(value: Any) -> TerminalScreenResult:
    payload = _mapping(value, "terminal screen result")
    _strict_object(
        payload,
        (
            "text",
            "cols",
            "rows",
            "cursor_row",
            "cursor_col",
            "cursor_visible",
            "extra",
        ),
        "terminal screen result",
    )
    extra = payload.get("extra", {})
    if not isinstance(extra, Mapping):
        raise ProtocolError("terminal screen extra must be an object")
    return TerminalScreenResult(
        _required_string(payload, "text"),
        _required_positive_uint16(payload, "cols"),
        _required_positive_uint16(payload, "rows"),
        _required_uint16(payload, "cursor_row"),
        _required_uint16(payload, "cursor_col"),
        _required_bool(payload, "cursor_visible"),
        dict(extra),
    )


def _terminal_state_result(value: Any) -> TerminalStateResult:
    payload = _mapping(value, "terminal state result")
    _strict_object(
        payload,
        ("state_base64", "cols", "rows"),
        "terminal state result",
    )
    encoded = _required_string(payload, "state_base64")
    try:
        state = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ProtocolError("terminal state_base64 is invalid") from error
    return TerminalStateResult(
        state,
        _required_positive_uint16(payload, "cols"),
        _required_positive_uint16(payload, "rows"),
    )


def _terminal_history_result(value: Any) -> TerminalHistoryResult:
    payload = _mapping(value, "terminal history result")
    _strict_object(payload, ("start", "next", "rows"), "terminal history result")
    rows = payload.get("rows")
    if not isinstance(rows, list):
        raise ProtocolError("terminal history rows must be an array")
    next_value = None
    if payload.get("next") is not None:
        next_value = _required_decimal(payload, "next")
    return TerminalHistoryResult(
        _required_decimal(payload, "start"),
        next_value,
        tuple(_render_row(item) for item in rows),
    )


def _terminal_wait_result(value: Any) -> TerminalWaitResult:
    payload = _mapping(value, "terminal wait result")
    _strict_object(payload, ("matched", "text"), "terminal wait result")
    return TerminalWaitResult(
        _required_bool(payload, "matched"),
        _required_string(payload, "text"),
    )


def _terminal_exit_outcome(value: Any) -> TerminalExitOutcome:
    payload = _mapping(value, "terminal exit outcome")
    kind = _required_enum(payload, "kind", ("exit", "signal", "unknown"))
    if kind == "exit":
        _strict_object(payload, ("kind", "code"), "terminal exit outcome")
        return TerminalExitCode("exit", _required_int32(payload, "code"))
    if kind == "signal":
        _strict_object(
            payload,
            ("kind", "signal", "core_dumped"),
            "terminal signal outcome",
        )
        signal = _required_int32(payload, "signal")
        if signal < 1:
            raise ProtocolError("terminal signal must be greater than zero")
        return TerminalExitSignal(
            "signal",
            signal,
            _required_bool(payload, "core_dumped"),
        )
    _strict_object(payload, ("kind", "reason"), "unknown terminal outcome")
    reason = _required_string(payload, "reason")
    if not reason:
        raise ProtocolError("unknown terminal outcome reason must not be empty")
    return TerminalExitUnknown("unknown", reason)


def _terminal_exit(value: Any) -> TerminalExit:
    payload = _mapping(value, "terminal exit")
    _strict_object(
        payload,
        ("outcome", "exited_at", "revision"),
        "terminal exit",
    )
    if "outcome" not in payload:
        raise ProtocolError("terminal exit omitted outcome")
    return TerminalExit(
        _terminal_exit_outcome(payload["outcome"]),
        _required_decimal(payload, "exited_at"),
        _required_decimal(payload, "revision"),
    )


def _terminal_wait_exit_result(value: Any) -> TerminalWaitExitResult:
    payload = _mapping(value, "terminal wait exit result")
    state = _required_enum(payload, "state", ("pending", "exited"))
    if state == "pending":
        _strict_object(
            payload,
            ("state", "terminal_id", "lifecycle", "revision"),
            "pending terminal wait exit result",
        )
        return TerminalWaitExitPending(
            "pending",
            _required_id(payload, ("terminal_id",), TerminalId),
            _required_enum(
                payload,
                "lifecycle",
                ("launching", "running"),
            ),  # type: ignore[arg-type]
            _required_decimal(payload, "revision"),
        )
    _strict_object(
        payload,
        (
            "state",
            "terminal_id",
            "lifecycle",
            "outcome",
            "exited_at",
            "revision",
        ),
        "exited terminal wait exit result",
    )
    if _required_enum(payload, "lifecycle", ("exited",)) != "exited":
        raise AssertionError("validated exited lifecycle")
    if "outcome" not in payload:
        raise ProtocolError("exited terminal result omitted outcome")
    return TerminalWaitExitExited(
        "exited",
        _required_id(payload, ("terminal_id",), TerminalId),
        "exited",
        _terminal_exit_outcome(payload["outcome"]),
        _required_decimal(payload, "exited_at"),
        _required_decimal(payload, "revision"),
    )


def _terminal_copy_result(value: Any) -> TerminalCopyResult:
    payload = _mapping(value, "terminal copy result")
    _strict_object(payload, ("mode", "text"), "terminal copy result")
    return TerminalCopyResult(
        _required_enum(
            payload,
            "mode",
            ("screen", "selection", "scrollback"),
        ),  # type: ignore[arg-type]
        _required_string(payload, "text"),
    )


def _process_info_result(value: Any) -> ProcessInfoResult:
    payload = _mapping(value, "process info result")
    _strict_object(
        payload,
        ("pid", "executable", "argv", "cwd", "foreground_cwd", "children"),
        "process info result",
    )
    argv = payload.get("argv")
    children = payload.get("children")
    if not isinstance(argv, list) or not all(isinstance(item, str) for item in argv):
        raise ProtocolError("process argv must be an array of strings")
    if not isinstance(children, list):
        raise ProtocolError("process children must be an array")
    decoded_children = tuple(
        _required_int({"child": item}, "child") for item in children
    )
    return ProcessInfoResult(
        _required_int(payload, "pid"),
        _optional_present_string(payload, "executable"),
        tuple(argv),
        _optional_present_string(payload, "cwd"),
        _optional_string(payload, "foreground_cwd"),
        decoded_children,
    )


def _viewer_resize_result(value: Any) -> ViewerResizeResult:
    payload = _mapping(value, "viewer resize result")
    _strict_object(
        payload,
        ("accepted", "size", "outcome"),
        "viewer resize result",
    )
    return ViewerResizeResult(
        _required_bool(payload, "accepted"),
        _size(payload.get("size")),
        _required_enum(
            payload,
            "outcome",
            ("applied", "passive", "superseded"),
        ),
    )


def _browser_viewer_resize_result(value: Any) -> BrowserViewerResizeResult:
    payload = _mapping(value, "browser viewer resize result")
    _strict_object(
        payload,
        ("accepted", "size", "outcome"),
        "browser viewer resize result",
    )
    size = _mapping(payload.get("size"), "pixel size")
    _strict_object(size, ("width_px", "height_px"), "pixel size")
    return BrowserViewerResizeResult(
        _required_bool(payload, "accepted"),
        PixelSize(
            _required_positive_uint32(size, "width_px"),
            _required_positive_uint32(size, "height_px"),
        ),
        _required_enum(
            payload,
            "outcome",
            ("applied", "passive", "superseded"),
        ),
    )


def _viewer_release_result(value: Any) -> ViewerReleaseResult:
    payload = _mapping(value, "viewer release result")
    _strict_object(payload, ("outcome",), "viewer release result")
    outcome: ViewAttachmentOutcome = _required_enum(
        payload,
        "outcome",
        ("applied", "passive", "superseded"),
    )
    return ViewerReleaseResult(outcome)


def _cell_pixels_result(value: Any) -> CellPixelsResult:
    payload = _mapping(value, "cell pixels result")
    _strict_object(
        payload,
        ("width_px", "height_px", "resized_terminals", "failures"),
        "cell pixels result",
    )
    resized = payload.get("resized_terminals")
    failures = payload.get("failures")
    if not isinstance(resized, list):
        raise ProtocolError("resized_terminals must be an array")
    if not isinstance(failures, Mapping) or not all(
        isinstance(key, str) and isinstance(item, str)
        for key, item in failures.items()
    ):
        raise ProtocolError("cell pixel failures must map strings to strings")
    return CellPixelsResult(
        _required_positive_uint32(payload, "width_px"),
        _required_positive_uint32(payload, "height_px"),
        tuple(
            _required_id({"id": item}, ("id",), TerminalId)
            for item in resized
        ),
        dict(failures),
    )


def _renderer_grant_result(value: Any) -> RendererGrant:
    payload = _mapping(value, "renderer grant result")
    _strict_object(
        payload,
        ("endpoint", "terminal_id", "token", "rights", "ttl_ms"),
        "renderer grant result",
    )
    rights = payload.get("rights")
    if (
        not isinstance(rights, list)
        or not rights
        or not all(isinstance(right, str) for right in rights)
    ):
        raise ProtocolError(
            "renderer grant rights must be a non-empty array of strings"
        )
    ttl_ms = _required_int(payload, "ttl_ms")
    if not 1 <= ttl_ms <= 60_000:
        raise ProtocolError("renderer grant ttl_ms must be between 1 and 60000")
    token = _required_string(payload, "token")
    if not token:
        raise ProtocolError("renderer grant token must be non-empty")
    return RendererGrant(
        token,
        endpoint=_required_string(payload, "endpoint"),
        terminal_id=_required_id(payload, ("terminal_id",), TerminalId),
        rights=rights,
        ttl_ms=ttl_ms,
    )


def _cursor(value: Any) -> Cursor:
    payload = _mapping(value, "cursor")
    _strict_object(payload, ("generation", "revision"), "cursor")
    generation = _required_generation(payload, "generation")
    return Cursor(generation, _required_decimal(payload, "revision"))


def _snapshot_list(
    payload: Mapping[str, Any],
    key: str,
    decode: Callable[[Any], SnapshotT],
) -> tuple[SnapshotT, ...]:
    values = payload.get(key)
    if not isinstance(values, list):
        raise ProtocolError(f"resource snapshot {key} must be an array")
    return tuple(decode(value) for value in values)


def _resource_snapshot(value: Any) -> ResourceSnapshot:
    payload = _mapping(value, "resource snapshot")
    _strict_object(
        payload,
        (
            "machine",
            "session",
            "workspaces",
            "screens",
            "panes",
            "tabs",
            "terminals",
            "browsers",
            "clients",
            "notifications",
            "agents",
            "frontend_projections",
            "sidebar_views",
            "cursor",
            "extra",
        ),
        "resource snapshot",
    )
    extra = payload.get("extra", {})
    if not isinstance(extra, Mapping):
        raise ProtocolError("resource snapshot extra must be an object")
    return ResourceSnapshot(
        _machine_snapshot(payload.get("machine")),
        _session_snapshot(payload.get("session")),
        _snapshot_list(payload, "workspaces", _workspace_snapshot),
        _snapshot_list(payload, "screens", _screen_snapshot),
        _snapshot_list(payload, "panes", _pane_snapshot),
        _snapshot_list(payload, "tabs", _tab_snapshot),
        _snapshot_list(payload, "terminals", _terminal_snapshot),
        _snapshot_list(payload, "browsers", _browser_snapshot),
        _snapshot_list(payload, "clients", _connected_client_snapshot),
        _snapshot_list(
            payload,
            "notifications",
            lambda item: _aux_snapshot(
                item,
                "notification",
                NotificationId,
                NotificationSnapshot,
            ),
        ),
        _snapshot_list(
            payload,
            "agents",
            lambda item: _aux_snapshot(
                item,
                "agent",
                AgentId,
                AgentSnapshot,
            ),
        ),
        _snapshot_list(
            payload,
            "frontend_projections",
            lambda item: _aux_snapshot(
                item,
                "frontend_projection",
                ProjectionId,
                FrontendProjectionSnapshot,
            ),
        ),
        _snapshot_list(
            payload,
            "sidebar_views",
            lambda item: _aux_snapshot(
                item,
                "sidebar_view",
                SidebarViewId,
                SidebarViewSnapshot,
            ),
        ),
        _cursor(payload.get("cursor")),
        dict(extra),
    )


_RESOURCE_KINDS = (
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
)


def _resource_entity_snapshot(
    resource: str,
    value: Any,
) -> ResourceEntitySnapshot:
    direct_decoders: Dict[str, Callable[[Any], ResourceEntitySnapshot]] = {
        "machine": _machine_snapshot,
        "session": _session_snapshot,
        "workspace": _workspace_snapshot,
        "screen": _screen_snapshot,
        "pane": _pane_snapshot,
        "tab": _tab_snapshot,
        "terminal": _terminal_snapshot,
        "browser": _browser_snapshot,
        "client": _connected_client_snapshot,
    }
    decoder = direct_decoders.get(resource)
    if decoder is not None:
        return decoder(value)
    auxiliary: Dict[str, tuple[str, Type[ResourceId], Type[Snapshot[Any]]]] = {
        "notification": ("notification", NotificationId, NotificationSnapshot),
        "agent": ("agent", AgentId, AgentSnapshot),
        "pairing_request": (
            "pairing_request",
            PairingRequestId,
            PairingRequestSnapshot,
        ),
        "frontend_projection": (
            "frontend_projection",
            ProjectionId,
            FrontendProjectionSnapshot,
        ),
        "sidebar_view": (
            "sidebar_view",
            SidebarViewId,
            SidebarViewSnapshot,
        ),
    }
    name, id_type, snapshot_type = auxiliary[resource]
    return _aux_snapshot(  # type: ignore[return-value, arg-type]
        value,
        name,
        id_type,
        snapshot_type,
    )


def _resource_change(value: Any) -> ResourceChange:
    payload = _mapping(value, "resource change")
    kind = _required_string(payload, "kind")
    if kind not in {"upsert", "delete"}:
        return Unknown(kind, dict(payload))
    resource = _required_enum(payload, "resource", _RESOURCE_KINDS)
    id_types: Dict[str, Type[ResourceId]] = {
        "machine": MachineId,
        "session": SessionId,
        "workspace": WorkspaceId,
        "screen": ScreenId,
        "pane": PaneId,
        "tab": TabId,
        "terminal": TerminalId,
        "browser": BrowserId,
        "client": ConnectedClientId,
        "notification": NotificationId,
        "agent": AgentId,
        "pairing_request": PairingRequestId,
        "frontend_projection": ProjectionId,
        "sidebar_view": SidebarViewId,
    }
    resource_id = _required_id(payload, ("id",), id_types[resource])
    sequence = _required_int(payload, "sequence")
    if kind == "delete":
        _strict_object(
            payload,
            ("kind", "sequence", "resource", "id"),
            "resource delete",
        )
        return ResourceDelete(
            "delete",
            sequence,
            resource,  # type: ignore[arg-type]
            resource_id,
        )
    _strict_object(
        payload,
        ("kind", "sequence", "resource", "id", "value"),
        "resource upsert",
    )
    snapshot = _resource_entity_snapshot(resource, payload.get("value"))
    if snapshot.id != resource_id:
        raise ProtocolError("resource upsert id does not match value.id")
    return ResourceUpsert(
        "upsert",
        sequence,
        resource,  # type: ignore[arg-type]
        resource_id,
        snapshot,
    )


def _event_item(value: Any) -> SessionEvent:
    payload = _mapping(value, "session event")
    kind = _required_string(payload, "kind")
    if kind == "snapshot":
        _strict_object(
            payload,
            ("kind", "cursor", "reset_reason", "snapshot"),
            "session snapshot item",
        )
        reset_reason = (
            _required_enum(
                payload,
                "reset_reason",
                ("initial", "generation_changed", "cursor_expired"),
            )
            if "reset_reason" in payload
            else None
        )
        return SessionSnapshotItem(
            "snapshot",
            _cursor(payload.get("cursor")),
            _resource_snapshot(payload.get("snapshot")),
            reset_reason,  # type: ignore[arg-type]
        )
    if kind == "delta":
        _strict_object(
            payload,
            (
                "kind",
                "cursor",
                "previous_revision",
                "revision",
                "changes",
            ),
            "session delta",
        )
        values = payload.get("changes")
        if not isinstance(values, list):
            raise ProtocolError("session delta changes must be an array")
        return SessionDelta(
            "delta",
            _cursor(payload.get("cursor")),
            _required_decimal(payload, "previous_revision"),
            _required_decimal(payload, "revision"),
            tuple(_resource_change(item) for item in values),
        )
    return Unknown(kind, dict(payload))


def _journal_record(value: Any) -> SessionJournalRecord:
    payload = _mapping(value, "session journal record")
    _strict_object(
        payload,
        (
            "sequence", "event_id", "schema_version", "kind", "class", "replay",
            "occurred_at_ms", "committed_at_ms", "producer", "authority",
            "causation_id", "correlation_id", "causation_depth", "subjects",
            "sensitivity", "payload", "resource_revision",
            "previous_resource_revision",
        ),
        "session journal record",
    )
    for required in ("authority", "payload"):
        if required not in payload:
            raise ProtocolError(
                f"session journal record omitted required field {required}"
            )
    producer = _mapping(payload.get("producer"), "journal producer")
    _strict_object(producer, ("kind", "id"), "journal producer")
    authority_value = payload.get("authority")
    authority: Optional[JournalAuthority] = None
    if authority_value is not None:
        authority_payload = _mapping(authority_value, "journal authority")
        _strict_object(
            authority_payload,
            ("principal_id", "lease_id", "generation", "role"),
            "journal authority",
        )
        authority = JournalAuthority(
            _required_string(authority_payload, "principal_id"),
            _required_string(authority_payload, "lease_id"),
            _required_string(authority_payload, "generation"),
            _required_string(authority_payload, "role"),
        )
    subject_values = payload.get("subjects")
    if not isinstance(subject_values, list):
        raise ProtocolError("journal subjects must be an array")
    subjects = []
    for subject_value in subject_values:
        subject = _mapping(subject_value, "journal subject")
        _strict_object(subject, ("kind", "id"), "journal subject")
        subjects.append(
            JournalSubject(
                _required_string(subject, "kind"),
                _required_string(subject, "id"),
            )
        )
    return SessionJournalRecord(
        _required_decimal(payload, "sequence"),
        _required_string(payload, "event_id"),
        _required_positive_uint32(payload, "schema_version"),
        _required_string(payload, "kind"),
        _required_enum(payload, "class", ("state", "observation", "effect", "checkpoint")),  # type: ignore[arg-type]
        _required_enum(payload, "replay", ("required", "advisory", "never")),  # type: ignore[arg-type]
        _required_decimal(payload, "occurred_at_ms"),
        _required_decimal(payload, "committed_at_ms"),
        JournalProducer(
            _required_string(producer, "kind"),
            _required_string(producer, "id"),
        ),
        authority,
        _required_nullable_string(payload, "causation_id"),
        _required_nullable_string(payload, "correlation_id"),
        _required_uint16(payload, "causation_depth"),
        tuple(subjects),
        _required_enum(
            payload,
            "sensitivity",
            ("public", "metadata", "sensitive", "secret"),
        ),  # type: ignore[arg-type]
        payload["payload"],
        _required_nullable_decimal(payload, "resource_revision"),
        _required_nullable_decimal(payload, "previous_resource_revision"),
    )


def _validate_journal_stream_item(
    record: SessionJournalRecord,
    cursor: Optional[Cursor],
) -> None:
    if cursor is None or record.sequence != cursor.revision:
        raise ProtocolError("journal sequence must match its stream cursor")


def _color(payload: Mapping[str, Any], key: str) -> str:
    value = _required_string(payload, key)
    if len(value) != 7:
        raise ProtocolError(f"resource field {key} must contain 7 characters")
    return value


def _required_nullable_color(
    payload: Mapping[str, Any],
    key: str,
) -> Optional[str]:
    value = _required_nullable_string(payload, key)
    if value is not None and len(value) != 7:
        raise ProtocolError(f"resource field {key} must contain 7 characters")
    return value


def _render_cursor(value: Any) -> RenderCursor:
    payload = _mapping(value, "render cursor")
    _strict_object(
        payload,
        ("x", "y", "style", "blink", "visible", "color"),
        "render cursor",
    )
    return RenderCursor(
        _required_uint16(payload, "x"),
        _required_uint16(payload, "y"),
        _required_enum(payload, "style", ("block", "underline", "bar")),
        _required_bool(payload, "blink"),
        _required_bool(payload, "visible"),
        _required_nullable_color(payload, "color"),
    )


def _render_run(value: Any) -> RenderRun:
    payload = _mapping(value, "render run")
    _strict_object(
        payload,
        ("text", "fg", "bg", "attrs", "underline", "width_hint"),
        "render run",
    )
    underline = (
        _required_enum(
            payload,
            "underline",
            ("single", "double", "curly", "dotted", "dashed"),
        )
        if "underline" in payload
        else None
    )
    return RenderRun(
        _required_string(payload, "text"),
        _required_nullable_color(payload, "fg"),
        _required_nullable_color(payload, "bg"),
        _required_int(payload, "attrs"),
        underline,  # type: ignore[arg-type]
        (
            _required_uint16(payload, "width_hint")
            if "width_hint" in payload
            else None
        ),
    )


def _render_row(value: Any) -> RenderRow:
    payload = _mapping(value, "render row")
    _strict_object(payload, ("row", "runs"), "render row")
    values = payload.get("runs")
    if not isinstance(values, list):
        raise ProtocolError("render row runs must be an array")
    return RenderRow(
        _required_uint16(payload, "row"),
        tuple(_render_run(item) for item in values),
    )


def _render_rows(payload: Mapping[str, Any]) -> tuple[RenderRow, ...]:
    values = payload.get("rows")
    if not isinstance(values, list):
        raise ProtocolError("render rows must be an array")
    return tuple(_render_row(item) for item in values)


def _render_snapshot(value: Any) -> RenderSnapshot:
    payload = _mapping(value, "render snapshot")
    _strict_object(
        payload,
        (
            "size",
            "cursor",
            "default_fg",
            "default_bg",
            "scrollback_rows",
            "rows",
        ),
        "render snapshot",
    )
    render_size = _size(payload.get("size"))
    rows = _render_rows(payload)
    if len(rows) != render_size.rows:
        raise ProtocolError("render snapshot rows must match size.rows")
    return RenderSnapshot(
        render_size,
        _render_cursor(payload.get("cursor")),
        _color(payload, "default_fg"),
        _color(payload, "default_bg"),
        _required_int(payload, "scrollback_rows"),
        rows,
    )


def _render_patch(value: Any) -> RenderPatch:
    payload = _mapping(value, "render patch")
    _strict_object(
        payload,
        (
            "cursor",
            "full_reset",
            "size",
            "default_fg",
            "default_bg",
            "scrollback_rows",
            "rows",
        ),
        "render patch",
    )
    full_reset = _required_bool(payload, "full_reset")
    render_size = _size(payload["size"]) if "size" in payload else None
    if render_size is not None and not full_reset:
        raise ProtocolError("render patch resize requires full_reset")
    rows = _render_rows(payload)
    if render_size is not None and len(rows) != render_size.rows:
        raise ProtocolError("full render patch rows must match size.rows")
    return RenderPatch(
        _render_cursor(payload.get("cursor")),
        full_reset,
        rows,
        render_size,
        _color(payload, "default_fg") if "default_fg" in payload else None,
        _color(payload, "default_bg") if "default_bg" in payload else None,
        (
            _required_int(payload, "scrollback_rows")
            if "scrollback_rows" in payload
            else None
        ),
    )


def _render_scroll(value: Any) -> RenderScroll:
    payload = _mapping(value, "render scroll")
    _strict_object(payload, ("offset", "at_bottom"), "render scroll")
    return RenderScroll(
        _required_decimal(payload, "offset"),
        _required_bool(payload, "at_bottom"),
    )


def _terminal_attach_item(value: Any) -> TerminalAttachItem:
    payload = _mapping(value, "terminal attach item")
    kind = _required_string(payload, "kind")
    if kind == "snapshot":
        _strict_object(
            payload,
            ("kind", "terminal_id", "render"),
            "terminal attach snapshot",
        )
        return TerminalAttachSnapshot(
            "snapshot",
            _required_id(payload, ("terminal_id",), TerminalId),
            _render_snapshot(payload.get("render")),
        )
    if kind == "patch":
        _strict_object(
            payload,
            ("kind", "terminal_id", "render"),
            "terminal attach patch",
        )
        return TerminalAttachPatch(
            "patch",
            _required_id(payload, ("terminal_id",), TerminalId),
            _render_patch(payload.get("render")),
        )
    if kind == "scroll":
        _strict_object(
            payload,
            ("kind", "terminal_id", "scroll"),
            "terminal attach scroll",
        )
        return TerminalAttachScroll(
            "scroll",
            _required_id(payload, ("terminal_id",), TerminalId),
            _render_scroll(payload.get("scroll")),
        )
    return Unknown(kind, dict(payload))


def _pixel_size(value: Any) -> PixelSize:
    payload = _mapping(value, "pixel size")
    _strict_object(payload, ("width_px", "height_px"), "pixel size")
    return PixelSize(
        _required_positive_uint32(payload, "width_px"),
        _required_positive_uint32(payload, "height_px"),
    )


def _browser_attach_item(value: Any) -> BrowserAttachItem:
    payload = _mapping(value, "browser attach item")
    kind = _required_string(payload, "kind")
    if kind == "snapshot":
        _strict_object(
            payload,
            ("kind", "browser", "size"),
            "browser attach snapshot",
        )
        return BrowserAttachSnapshot(
            "snapshot",
            _browser_snapshot(payload.get("browser")),
            _pixel_size(payload.get("size")),
        )
    if kind == "frame":
        _strict_object(
            payload,
            (
                "kind",
                "mime_type",
                "data_base64",
                "width_px",
                "height_px",
                "pointer_frame_seq",
            ),
            "browser attach frame",
        )
        data = _required_string(payload, "data_base64")
        try:
            base64.b64decode(data.encode("ascii"), validate=True)
        except (UnicodeEncodeError, binascii.Error) as error:
            raise ProtocolError("browser frame data_base64 is invalid") from error
        return BrowserAttachFrame(
            "frame",
            _required_enum(
                payload,
                "mime_type",
                ("image/png", "image/jpeg"),
            ),  # type: ignore[arg-type]
            data,
            _required_positive_uint32(payload, "width_px"),
            _required_positive_uint32(payload, "height_px"),
            _required_nullable_decimal_int(payload, "pointer_frame_seq"),
        )
    if kind == "state":
        _strict_object(
            payload,
            ("kind", "url", "title", "loading"),
            "browser attach state",
        )
        return BrowserAttachState(
            "state",
            _required_string(payload, "url"),
            _required_string(payload, "title"),
            _required_bool(payload, "loading"),
        )
    return Unknown(kind, dict(payload))


def _sidebar_attach_item(value: Any) -> SidebarAttachItem:
    payload = _mapping(value, "sidebar attach item")
    kind = _required_string(payload, "kind")
    if kind == "snapshot":
        _strict_object(
            payload,
            ("kind", "sidebar_view", "render"),
            "sidebar attach snapshot",
        )
        sidebar = _aux_snapshot(
            payload.get("sidebar_view"),
            "sidebar_view",
            SidebarViewId,
            SidebarViewSnapshot,
        )
        return SidebarAttachSnapshot(
            "snapshot",
            sidebar,
            _render_snapshot(payload.get("render")),
        )
    if kind == "patch":
        _strict_object(
            payload,
            ("kind", "sidebar_view_id", "render"),
            "sidebar attach patch",
        )
        return SidebarAttachPatch(
            "patch",
            _required_id(payload, ("sidebar_view_id",), SidebarViewId),
            _render_patch(payload.get("render")),
        )
    if kind == "scroll":
        _strict_object(
            payload,
            ("kind", "sidebar_view_id", "scroll"),
            "sidebar attach scroll",
        )
        return SidebarAttachScroll(
            "scroll",
            _required_id(payload, ("sidebar_view_id",), SidebarViewId),
            _render_scroll(payload.get("scroll")),
        )
    return Unknown(kind, dict(payload))


class _Handle(Generic[IdT, SnapshotT]):
    _id_type: Type[IdT]
    _selector_key: str
    _get_operation: Operation
    _decode_snapshot: Callable[[Any], SnapshotT]

    def __init__(
        self,
        client: "Client",
        selector: Selector[IdT],
        scope: Optional[Mapping[str, str]] = None,
        snapshot: Optional[SnapshotT] = None,
    ) -> None:
        self._client = client
        self.selector = selector
        self._scope = dict(scope or {})
        self._snapshot = snapshot

    @property
    def id(self) -> Optional[IdT]:
        return self.selector.value if self.selector.kind == "id" else None  # type: ignore[return-value]

    @property
    def snapshot(self) -> Optional[SnapshotT]:
        return self._snapshot

    def _params(self) -> Dict[str, Any]:
        return {**self._scope, self._selector_key: self.selector.encode()}

    def refresh(self) -> SnapshotT:
        snapshot = self._decode_snapshot(
            self._client._read(self._get_operation, self._params())
        )
        self._snapshot = snapshot
        return snapshot


@dataclass(frozen=True)
class CreatedPath:
    kind: Literal["workspace", "terminal", "browser"]
    workspace: "Workspace"
    screen: Optional["Screen"] = None
    pane: Optional["Pane"] = None
    tab: Optional["Tab"] = None
    terminal: Optional["Terminal"] = None
    browser: Optional["Browser"] = None

    @property
    def content(self) -> Optional[Union["Terminal", "Browser"]]:
        return self.terminal or self.browser


class Client:
    """Synchronous resource API client with no implicit mutation retries."""

    def __init__(
        self,
        socket_path: Optional[str] = None,
        session: str = "main",
        timeout: float = 10.0,
        *,
        local_executor: Optional[LocalExecutor] = None,
        random_hex_128: Optional[RandomHex128] = None,
    ) -> None:
        self.socket_path = (
            socket_path or env_socket_path() or default_socket_path(session)
        )
        self.timeout = timeout
        self._connection = ProtocolConnection(self.socket_path, timeout)
        self._local_executor = local_executor
        self._random_hex_128 = random_hex_128 or (lambda: secrets.token_hex(16))
        self._request_context = threading.local()

    @property
    def closed(self) -> bool:
        return self._connection.closed

    def close(self) -> None:
        self._connection.close()

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

    def with_request_options(
        self,
        request_options: RequestOptions,
        function: Callable[..., ValueT],
        *args: Any,
        **kwargs: Any,
    ) -> ValueT:
        """Runs exactly one SDK call with a local deadline and cancellation."""
        return self._invoke_with_request_options(
            function,
            args,
            kwargs,
            request_options,
            None,
        )

    def machine(self, selector: SelectorInput[MachineId]) -> "Machine":
        return Machine(self, _selector(selector, MachineId))

    def session(
        self,
        selector: SelectorInput[SessionId],
        *,
        machine: Optional[SelectorInput[MachineId]] = None,
    ) -> "Session":
        scope = {
            "machine": (
                Selector.current().encode()
                if machine is None
                else encode_selector(machine, MachineId)
            )
        }
        return Session(self, _selector(selector, SessionId), scope)

    def list_machines(self) -> List["Machine"]:
        values = _list_payload(
            self._read(Operations.MACHINE_LIST, {}),
            "machines",
        )
        return [
            Machine(
                self,
                Selector.by_id(snapshot.id),
                snapshot=snapshot,
            )
            for snapshot in map(_machine_snapshot, values)
        ]

    def find_machines_by_name(self, name: str) -> List["Machine"]:
        return [
            item
            for item in self.list_machines()
            if item.snapshot is not None and item.snapshot.name == name
        ]

    def _read(
        self,
        operation: Operation,
        params: Mapping[str, Any],
        *,
        _abandoned_result_decoder: Optional[Callable[[Any], Any]] = None,
    ) -> Any:
        if operation.operation_class not in {"read", "connection_control"}:
            raise ValueError(f"{operation.wire_name} is not a read/control operation")
        return self._request(
            operation,
            params,
            _abandoned_result_decoder=_abandoned_result_decoder,
        )

    def _request(
        self,
        operation: Operation,
        params: Mapping[str, Any],
        *,
        idempotency_key: Optional[str] = None,
        _abandoned_result_decoder: Optional[Callable[[Any], Any]] = None,
    ) -> Any:
        context: Optional[_RequestContext] = getattr(
            self._request_context,
            "value",
            None,
        )
        return self._connection.request(
            operation.wire_name,
            params,
            idempotency_key=idempotency_key,
            timeout=context.options.timeout if context is not None else None,
            cancel_event=context.cancel_event if context is not None else None,
            _abandoned_result_decoder=_abandoned_result_decoder,
        )

    def _invoke_with_request_options(
        self,
        function: Callable[..., ValueT],
        args: Sequence[Any],
        kwargs: Mapping[str, Any],
        request_options: RequestOptions,
        task_cancel_event: Optional[threading.Event],
    ) -> ValueT:
        if not isinstance(request_options, RequestOptions):
            raise TypeError("request_options must be RequestOptions")
        cancel_event = _CancellationSignal(
            request_options.cancellation,
            task_cancel_event,
        )
        if cancel_event.is_set():
            raise CancelledError(
                getattr(function, "__name__", "request"),
                dispatched=False,
            )
        previous = getattr(self._request_context, "value", _UNSET)
        self._request_context.value = _RequestContext(
            request_options,
            cancel_event,
        )
        try:
            return function(*args, **kwargs)
        finally:
            if previous is _UNSET:
                del self._request_context.value
            else:
                self._request_context.value = previous

    def _mutation(
        self,
        operation: Operation,
        params: Mapping[str, Any],
        idempotency_key: Optional[str],
        expected_revision: Optional[str],
        decode: Callable[[Any], ValueT],
    ) -> MutationResult[ValueT]:
        if not operation.is_mutation:
            raise ValueError(f"{operation.wire_name} is not a mutation")
        request_params = dict(params)
        if expected_revision is not None:
            if not operation.accepts_expected_revision:
                raise TypeError(
                    f"{operation.wire_name} does not accept expected_revision"
                )
            if (
                not isinstance(expected_revision, str)
                or not expected_revision
                or any(character not in "0123456789" for character in expected_revision)
                or (len(expected_revision) > 1 and expected_revision.startswith("0"))
                or int(expected_revision) > 18_446_744_073_709_551_615
            ):
                raise ValueError(
                    "expected_revision must be a canonical uint64 decimal string"
                )
            request_params["expected_revision"] = expected_revision
        if idempotency_key is None:
            random_value = self._random_hex_128()
            if (
                not isinstance(random_value, str)
                or len(random_value) != 32
                or any(
                    character not in "0123456789abcdef"
                    for character in random_value
                )
            ):
                raise ValueError(
                    "random_hex_128 must return exactly 128 lowercase-hex bits"
                )
            key = f"py-{random_value}"
        else:
            key = idempotency_key
        try:
            raw = self._request(
                operation,
                request_params,
                idempotency_key=key,
            )
        except (CmuxConnectionError, TimeoutError, CancelledError) as error:
            if isinstance(error, CancelledError) and not error.dispatched:
                raise
            raise MutationTransportError(
                operation.wire_name,
                key,
                error,
            ) from error
        return self._decode_mutation(raw, decode, key, operation.wire_name)

    def _mutation_handle(
        self,
        operation: Operation,
        params: Mapping[str, Any],
        idempotency_key: Optional[str],
        expected_revision: Optional[str],
        decode_snapshot: Callable[[Any], SnapshotT],
        make_handle: Callable[[SnapshotT], ValueT],
    ) -> MutationResult[ValueT]:
        return self._mutation(
            operation,
            params,
            idempotency_key,
            expected_revision,
            lambda value: make_handle(decode_snapshot(value)),
        )

    def _created(
        self,
        operation: Operation,
        params: Mapping[str, Any],
        idempotency_key: Optional[str] = None,
        expected_revision: Optional[str] = None,
    ) -> MutationResult[CreatedPath]:
        return self._mutation(
            operation,
            params,
            idempotency_key,
            expected_revision,
            lambda value: self._decode_created_path(value, params),
        )

    def _control(
        self,
        operation: Operation,
        params: Mapping[str, Any],
        decode: Callable[[Any], ValueT],
    ) -> ValueT:
        if operation.operation_class != "connection_control":
            raise ValueError(f"{operation.wire_name} is not connection control")
        return decode(self._request(operation, params))

    def _open_stream(
        self,
        operation: Operation,
        params: Mapping[str, Any],
        decode: Callable[[Any], StreamValueT],
        *,
        validate_item: Optional[
            Callable[[StreamValueT, Optional[Cursor]], None]
        ] = None,
    ) -> ResourceStream[StreamValueT]:
        if operation.operation_class != "stream_open":
            raise ValueError(f"{operation.wire_name} is not a stream operation")
        context: Optional[_RequestContext] = getattr(
            self._request_context,
            "value",
            None,
        )
        return self._connection.open_stream(
            operation.wire_name,
            params,
            decode,
            timeout=context.options.timeout if context is not None else None,
            cancel_event=context.cancel_event if context is not None else None,
            validate_item=validate_item,
        )

    def _local(self, operation: Operation, params: Mapping[str, Any]) -> Any:
        if operation.operation_class != "local":
            raise ValueError(f"{operation.wire_name} is not local")
        if self._local_executor is None:
            raise RuntimeError(
                f"{operation.wire_name} requires an explicit local_executor"
            )
        return self._local_executor(operation.wire_name, dict(params))

    def _decode_mutation(
        self,
        raw: Any,
        decode: Callable[[Any], ValueT],
        _idempotency_key: str,
        _operation: str,
    ) -> MutationResult[ValueT]:
        payload = _mapping(raw, "mutation result")
        _strict_object(
            payload,
            ("value", "generation", "revision", "replayed"),
            "mutation result",
        )
        if "value" not in payload:
            raise ProtocolError("mutation result omitted value")
        return MutationResult(
            decode(payload["value"]),
            _required_generation(payload, "generation"),
            _required_decimal(payload, "revision"),
            _required_bool(payload, "replayed"),
        )

    def _decode_created_path(
        self,
        value: Any,
        request_params: Mapping[str, Any],
    ) -> CreatedPath:
        payload = _mapping(value, "created path")
        kind = _required_enum(
            payload,
            "kind",
            ("workspace", "terminal", "browser"),
        )
        if kind == "workspace":
            allowed = ("kind", "workspace_id")
        elif kind == "terminal":
            allowed = (
                "kind",
                "workspace_id",
                "screen_id",
                "pane_id",
                "tab_id",
                "terminal_id",
            )
        else:
            allowed = (
                "kind",
                "workspace_id",
                "screen_id",
                "pane_id",
                "tab_id",
                "browser_id",
            )
        _strict_object(payload, allowed, "created path")
        workspace_id = _required_id(payload, ("workspace_id",), WorkspaceId)
        session_scope = {
            "machine": str(request_params.get("machine", "current")),
            "session": str(request_params.get("session", "current")),
        }
        workspace = Workspace(
            self,
            Selector.by_id(workspace_id),
            session_scope,
        )
        if kind == "workspace":
            return CreatedPath("workspace", workspace)
        screen_id = _required_id(payload, ("screen_id",), ScreenId)
        pane_id = _required_id(payload, ("pane_id",), PaneId)
        tab_id = _required_id(payload, ("tab_id",), TabId)
        screen_scope = {**session_scope, "workspace": str(workspace_id)}
        screen = Screen(self, Selector.by_id(screen_id), screen_scope)
        pane_scope = {**screen_scope, "screen": str(screen_id)}
        pane = Pane(self, Selector.by_id(pane_id), pane_scope)
        tab_scope = {**pane_scope, "pane": str(pane_id)}
        tab = Tab(self, Selector.by_id(tab_id), tab_scope)
        content_scope = {**tab_scope, "tab": str(tab_id)}
        if kind == "terminal":
            terminal_id = _required_id(payload, ("terminal_id",), TerminalId)
            return CreatedPath(
                "terminal",
                workspace,
                screen,
                pane,
                tab,
                Terminal(self, Selector.by_id(terminal_id), content_scope),
            )
        browser_id = _required_id(payload, ("browser_id",), BrowserId)
        return CreatedPath(
            "browser",
            workspace,
            screen,
            pane,
            tab,
            browser=Browser(self, Selector.by_id(browser_id), content_scope),
        )

    def _decode_creation_resolution(
        self,
        value: Any,
        request_params: Mapping[str, Any],
    ) -> CreationResolution[CreatedPath]:
        payload = _mapping(value, "creation resolution")
        _strict_object(
            payload,
            (
                "correlation_key",
                "state",
                "recovery",
                "operation",
                "idempotency_key",
                "created_path",
                "generation",
                "revision",
            ),
            "creation resolution",
        )
        correlation_key = _required_string(payload, "correlation_key")
        if not correlation_key or len(correlation_key.encode("utf-8")) > 128:
            raise ProtocolError(
                "creation correlation_key must contain 1 to 128 UTF-8 bytes"
            )
        state = _required_enum(
            payload,
            "state",
            ("pending", "created", "not_applied", "indeterminate"),
        )
        recovery = _required_enum(
            payload,
            "recovery",
            (
                "retry_same_idempotency_key",
                "retry_new_idempotency_key",
                "wait",
                "none",
                "do_not_retry",
            ),
        )
        valid_recovery = {
            "pending": ("wait",),
            "created": ("none",),
            "not_applied": (
                "retry_same_idempotency_key",
                "retry_new_idempotency_key",
            ),
            "indeterminate": ("do_not_retry",),
        }
        if recovery not in valid_recovery[state]:
            raise ProtocolError(
                "creation state and recovery strategy do not match"
            )

        operation = _optional_present_string(payload, "operation")
        if operation == "":
            raise ProtocolError("creation operation must not be empty")
        idempotency_key = _optional_present_string(
            payload,
            "idempotency_key",
        )
        if idempotency_key is not None and (
            not idempotency_key
            or len(idempotency_key.encode("utf-8")) > 128
        ):
            raise ProtocolError(
                "creation idempotency_key must contain 1 to 128 UTF-8 bytes"
            )
        created_path = None
        if "created_path" in payload:
            if payload["created_path"] is None:
                raise ProtocolError(
                    "creation created_path must be an object when present"
                )
            created_path = self._decode_created_path(
                payload["created_path"],
                request_params,
            )
        generation = None
        if "generation" in payload:
            generation = _required_generation(payload, "generation")
        revision = None
        if "revision" in payload:
            revision = _required_decimal(payload, "revision")
        if state == "created" and (
            created_path is None
            or generation is None
            or revision is None
        ):
            raise ProtocolError(
                "created resolution requires created_path, generation, and revision"
            )
        return CreationResolution(
            correlation_key,
            state,  # type: ignore[arg-type]
            recovery,  # type: ignore[arg-type]
            operation,
            idempotency_key,
            created_path,
            generation,
            revision,
        )


class Machine(_Handle[MachineId, MachineSnapshot]):
    _id_type = MachineId
    _selector_key = "machine"
    _get_operation = Operations.MACHINE_GET
    _decode_snapshot = staticmethod(_machine_snapshot)

    def session(self, selector: SelectorInput[SessionId]) -> "Session":
        return Session(
            self._client,
            _selector(selector, SessionId),
            {"machine": self.selector.encode()},
        )

    def list_sessions(self) -> List["Session"]:
        values = _list_payload(
            self._client._read(
                Operations.SESSION_LIST,
                {"machine": self.selector.encode()},
            ),
            "sessions",
        )
        result: List[Session] = []
        for value in values:
            snapshot = _session_snapshot(value)
            result.append(
                Session(
                    self._client,
                    Selector.by_id(snapshot.id),
                    {"machine": self.selector.encode()},
                    snapshot,
                )
            )
        return result

    def find_sessions_by_name(self, name: str) -> List["Session"]:
        return [
            item
            for item in self.list_sessions()
            if item.snapshot is not None and item.snapshot.name == name
        ]

    def open_session(
        self,
        selector: SelectorInput[SessionId],
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Session"]:
        selected = _selector(selector, SessionId)
        return self._client._mutation_handle(
            Operations.SESSION_OPEN,
            {
                "machine": self.selector.encode(),
                "session": selected.encode(),
            },
            idempotency_key,
            expected_revision,
            _session_snapshot,
            lambda snapshot: Session(
                self._client,
                Selector.by_id(snapshot.id),
                {"machine": self.selector.encode()},
                snapshot,
            ),
        )

class SessionCreation:
    def __init__(self, session: "Session") -> None:
        self._session = session

    def resolve(
        self,
        correlation_key: str,
    ) -> CreationResolution[CreatedPath]:
        if not isinstance(correlation_key, str):
            raise TypeError("correlation_key must be a string")
        if (
            not correlation_key
            or len(correlation_key.encode("utf-8")) > 128
        ):
            raise ValueError(
                "correlation_key must contain 1 to 128 UTF-8 bytes"
            )
        params = {
            **self._session._params(),
            "correlation_key": correlation_key,
        }
        return self._session._client._decode_creation_resolution(
            self._session._client._read(
                Operations.SESSION_CREATION_RESOLVE,
                params,
            ),
            params,
        )


class Session(_Handle[SessionId, SessionSnapshot]):
    _id_type = SessionId
    _selector_key = "session"
    _get_operation = Operations.SESSION_GET
    _decode_snapshot = staticmethod(_session_snapshot)

    @property
    def creation(self) -> SessionCreation:
        return SessionCreation(self)

    def workspace(self, selector: SelectorInput[WorkspaceId]) -> "Workspace":
        return Workspace(
            self._client,
            _selector(selector, WorkspaceId),
            {**self._scope, "session": self.selector.encode()},
        )

    def connected_client(
        self, selector: SelectorInput[ConnectedClientId]
    ) -> "ConnectedClient":
        return ConnectedClient(
            self._client,
            _selector(selector, ConnectedClientId),
            {**self._scope, "session": self.selector.encode()},
        )

    def pairing_request(
        self,
        selector: SelectorInput[PairingRequestId],
    ) -> "PairingRequest":
        return PairingRequest(
            self._client,
            _selector(selector, PairingRequestId),
            {**self._scope, "session": self.selector.encode()},
        )

    def terminal(self, selector: SelectorInput[TerminalId]) -> "Terminal":
        return Terminal(
            self._client,
            _selector(selector, TerminalId),
            {**self._scope, "session": self.selector.encode()},
        )

    def browser(self, selector: SelectorInput[BrowserId]) -> "Browser":
        return Browser(
            self._client,
            _selector(selector, BrowserId),
            {**self._scope, "session": self.selector.encode()},
        )

    def sidebar_view(
        self, selector: SelectorInput[SidebarViewId]
    ) -> "SidebarView":
        return SidebarView(
            self._client,
            _selector(selector, SidebarViewId),
            {**self._scope, "session": self.selector.encode()},
        )

    def full_snapshot(self) -> ResourceSnapshot:
        snapshot = _resource_snapshot(
            self._client._read(Operations.SESSION_SNAPSHOT, self._params())
        )
        return snapshot

    def ping(self) -> PingResult:
        return _ping_result(
            self._client._read(Operations.SESSION_PING, self._params())
        )

    def events(
        self, options: SessionEventsOptions = SessionEventsOptions()
    ) -> ResourceStream[SessionEvent]:
        return self._client._open_stream(
            Operations.SESSION_EVENTS,
            {**self._params(), **_options(options)},
            _event_item,
        )

    def journal(
        self, options: SessionJournalOptions = SessionJournalOptions()
    ) -> ResourceStream[SessionJournalRecord]:
        return self._client._open_stream(
            Operations.SESSION_JOURNAL_SUBSCRIBE,
            {**self._params(), **_journal_options(options)},
            _journal_record,
            validate_item=_validate_journal_stream_item,
        )

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult[ShutdownResult]:
        return self.shutdown(
            idempotency_key=idempotency_key,
            expected_revision=expected_revision,
        )

    def shutdown(
        self,
        *,
        force: bool = False,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[ShutdownResult]:
        return self._client._mutation(
            Operations.SESSION_SHUTDOWN,
            {**self._params(), "force": force},
            idempotency_key,
            expected_revision,
            _shutdown_result,
        )

    def reload_config(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult[ReloadConfigResult]:
        return self._client._mutation(
            Operations.SESSION_RELOAD_CONFIG,
            self._params(),
            idempotency_key,
            expected_revision,
            _reload_config_result,
        )

    def update_terminal_defaults(
        self,
        defaults: Mapping[str, Any],
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[TerminalDefaultsSnapshot]:
        return self._client._mutation(
            Operations.SESSION_TERMINAL_DEFAULTS_UPDATE,
            {**self._params(), **dict(defaults)},
            idempotency_key,
            expected_revision,
            _terminal_defaults_snapshot,
        )

    def set_window_title(
        self, title: str, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.WINDOW_TITLE_SET,
            {**self._params(), "title": title},
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def clear_window_title(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.WINDOW_TITLE_CLEAR,
            self._params(),
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def list_workspaces(self) -> List["Workspace"]:
        values = _list_payload(
            self._client._read(
                Operations.WORKSPACE_LIST,
                {**self._scope, "session": self.selector.encode()},
            ),
            "workspaces",
        )
        scope = {**self._scope, "session": self.selector.encode()}
        result: List[Workspace] = []
        for value in values:
            snapshot = _workspace_snapshot(value)
            result.append(
                Workspace(
                    self._client,
                    Selector.by_id(snapshot.id),
                    scope,
                    snapshot,
                )
            )
        return result

    def find_workspaces_by_name(self, name: str) -> List["Workspace"]:
        return [
            item
            for item in self.list_workspaces()
            if item.snapshot is not None and item.snapshot.name == name
        ]

    def create_workspace(
        self,
        options: CreateWorkspaceOptions = CreateWorkspaceOptions(),
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[CreatedPath]:
        params = {
            **self._scope,
            "session": self.selector.encode(),
            **_options(options),
        }
        if options.initial_content == "empty":
            params.pop("argv", None)
            params.pop("cwd", None)
            params.pop("env", None)
        return self._client._created(
            Operations.WORKSPACE_CREATE,
            params,
            idempotency_key,
            expected_revision,
        )

    def list_connected_clients(self) -> List["ConnectedClient"]:
        values = _list_payload(
            self._client._read(
                Operations.CLIENT_LIST,
                {**self._scope, "session": self.selector.encode()},
            ),
            "clients",
        )
        scope = {**self._scope, "session": self.selector.encode()}
        result: List[ConnectedClient] = []
        for value in values:
            snapshot = _connected_client_snapshot(value)
            result.append(
                ConnectedClient(
                    self._client,
                    Selector.by_id(snapshot.id),
                    scope,
                    snapshot,
                )
            )
        return result

    def list_terminals(self) -> List["Terminal"]:
        values = _list_payload(
            self._client._read(
                Operations.TERMINAL_LIST,
                {**self._scope, "session": self.selector.encode()},
            ),
            "terminals",
        )
        scope = {**self._scope, "session": self.selector.encode()}
        result: List[Terminal] = []
        for value in values:
            snapshot = _terminal_snapshot(value)
            result.append(
                Terminal(
                    self._client,
                    Selector.by_id(snapshot.id),
                    scope,
                    snapshot,
                )
            )
        return result

    def list_browsers(self) -> List["Browser"]:
        values = _list_payload(
            self._client._read(
                Operations.BROWSER_LIST,
                {**self._scope, "session": self.selector.encode()},
            ),
            "browsers",
        )
        scope = {**self._scope, "session": self.selector.encode()}
        result: List[Browser] = []
        for value in values:
            snapshot = _browser_snapshot(value)
            result.append(
                Browser(
                    self._client,
                    Selector.by_id(snapshot.id),
                    scope,
                    snapshot,
                )
            )
        return result

    def list_pairing_requests(self) -> List["PairingRequest"]:
        values = _list_payload(
            self._client._read(
                Operations.PAIRING_REQUEST_LIST,
                {**self._scope, "session": self.selector.encode()},
            ),
            "pairing_requests",
        )
        scope = {**self._scope, "session": self.selector.encode()}
        result: List[PairingRequest] = []
        for value in values:
            snapshot = _aux_snapshot(
                value,
                "pairing_request",
                PairingRequestId,
                PairingRequestSnapshot,
                parent_key="session",
                parent_type=SessionId,
            )
            result.append(
                PairingRequest(
                    self._client,
                    Selector.by_id(snapshot.id),
                    scope,
                    snapshot,
                )
            )
        return result

    def projection(self) -> "FrontendProjection":
        value = self._client._read(
            Operations.FRONTEND_PROJECTION_GET,
            {
                **self._scope,
                "session": self.selector.encode(),
                "frontend_projection": "current",
            },
        )
        snapshot = _aux_snapshot(
            value,
            "frontend_projection",
            ProjectionId,
            FrontendProjectionSnapshot,
            parent_key="session",
            parent_type=SessionId,
        )
        return FrontendProjection(
            self._client,
            Selector.by_id(snapshot.id),
            {**self._scope, "session": self.selector.encode()},
            snapshot,
        )

    def list_notifications(self, limit: Optional[int] = None) -> List["Notification"]:
        params: Dict[str, Any] = {
            **self._scope,
            "session": self.selector.encode(),
        }
        if limit is not None:
            params["limit"] = limit
        values = _list_payload(
            self._client._read(
                Operations.NOTIFICATION_LIST,
                params,
            ),
            "notifications",
        )
        return [
            Notification(
                self._client,
                Selector.by_id(snapshot.id),
                {**self._scope, "session": self.selector.encode()},
                snapshot,
            )
            for snapshot in (
                _aux_snapshot(
                    value,
                    "notification",
                    NotificationId,
                    NotificationSnapshot,
                    parent_key="session",
                    parent_type=SessionId,
                )
                for value in values
            )
        ]

    def create_notification(
        self,
        options: NotificationOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Notification"]:
        scope = {**self._scope, "session": self.selector.encode()}
        return self._client._mutation_handle(
            Operations.NOTIFICATION_CREATE,
            {**scope, **_options(options)},
            idempotency_key,
            expected_revision,
            lambda value: _aux_snapshot(
                value,
                "notification",
                NotificationId,
                NotificationSnapshot,
                parent_key="session",
                parent_type=SessionId,
            ),
            lambda snapshot: Notification(
                self._client,
                Selector.by_id(snapshot.id),
                scope,
                snapshot,
            ),
        )

    def list_agents(
        self,
        *,
        terminal_id: Optional[TerminalId] = None,
        state: Optional[str] = None,
    ) -> List["Agent"]:
        params: Dict[str, Any] = {
            **self._scope,
            "session": self.selector.encode(),
        }
        if terminal_id is not None:
            params["terminal_id"] = str(terminal_id)
        if state is not None:
            params["state"] = state
        values = _list_payload(
            self._client._read(
                Operations.AGENT_LIST,
                params,
            ),
            "agents",
        )
        return [
            Agent(
                self._client,
                Selector.by_id(snapshot.id),
                {**self._scope, "session": self.selector.encode()},
                snapshot,
            )
            for snapshot in (
                _aux_snapshot(
                    value,
                    "agent",
                    AgentId,
                    AgentSnapshot,
                    parent_key="session",
                    parent_type=SessionId,
                )
                for value in values
            )
        ]

    def report_agent(
        self,
        options: AgentReportOptions,
        *,
        idempotency_key: Optional[str] = None,
        expected_revision: Optional[str] = None,
    ) -> MutationResult["Agent"]:
        scope = {**self._scope, "session": self.selector.encode()}
        return self._client._mutation_handle(
            Operations.AGENT_REPORT,
            {**scope, **_options(options)},
            idempotency_key,
            expected_revision,
            lambda value: _aux_snapshot(
                value,
                "agent",
                AgentId,
                AgentSnapshot,
                parent_key="session",
                parent_type=SessionId,
            ),
            lambda snapshot: Agent(
                self._client,
                Selector.by_id(snapshot.id),
                scope,
                snapshot,
            ),
        )


class Workspace(_Handle[WorkspaceId, WorkspaceSnapshot]):
    _id_type = WorkspaceId
    _selector_key = "workspace"
    _get_operation = Operations.WORKSPACE_GET
    _decode_snapshot = staticmethod(_workspace_snapshot)

    def screen(self, selector: SelectorInput[ScreenId]) -> "Screen":
        return Screen(
            self._client,
            _selector(selector, ScreenId),
            {**self._scope, "workspace": self.selector.encode()},
        )

    def list_screens(self) -> List["Screen"]:
        scope = {**self._scope, "workspace": self.selector.encode()}
        values = _list_payload(
            self._client._read(Operations.SCREEN_LIST, scope),
            "screens",
        )
        result: List[Screen] = []
        for value in values:
            snapshot = _screen_snapshot(value)
            result.append(
                Screen(
                    self._client,
                    Selector.by_id(snapshot.id),
                    scope,
                    snapshot,
                )
            )
        return result

    def find_screens_by_name(self, name: str) -> List["Screen"]:
        return [
            item
            for item in self.list_screens()
            if item.snapshot is not None and item.snapshot.name == name
        ]

    def create_screen(
        self,
        options: CreateScreenOptions = CreateScreenOptions(),
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[CreatedPath]:
        scope = {**self._scope, "workspace": self.selector.encode()}
        return self._client._created(
            Operations.SCREEN_CREATE,
            {**scope, **_options(options)},
            idempotency_key,
            expected_revision,
        )

    def rename(
        self, name: str, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Workspace"]:
        return self._client._mutation_handle(
            Operations.WORKSPACE_RENAME,
            {**self._params(), "name": name},
            idempotency_key,
            expected_revision,
            _workspace_snapshot,
            lambda snapshot: Workspace(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def move(
        self,
        index: int,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Workspace"]:
        params = self._params()
        params["index"] = index
        return self._client._mutation_handle(
            Operations.WORKSPACE_MOVE,
            params,
            idempotency_key,
            expected_revision,
            _workspace_snapshot,
            lambda snapshot: Workspace(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def focus(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult["Workspace"]:
        return self._client._mutation_handle(
            Operations.WORKSPACE_FOCUS,
            self._params(),
            idempotency_key,
            expected_revision,
            _workspace_snapshot,
            lambda snapshot: Workspace(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationReceipt:
        return self._client._mutation(
            Operations.WORKSPACE_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def run(
        self,
        options: RunOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[CreatedPath]:
        return self._client._created(
            Operations.WORKSPACE_RUN,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
        )

    def apply_layout(
        self,
        options: LayoutApplyOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Workspace"]:
        return self._client._mutation_handle(
            Operations.WORKSPACE_LAYOUT_APPLY,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
            _workspace_snapshot,
            lambda snapshot: Workspace(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )


class Screen(_Handle[ScreenId, ScreenSnapshot]):
    _id_type = ScreenId
    _selector_key = "screen"
    _get_operation = Operations.SCREEN_GET
    _decode_snapshot = staticmethod(_screen_snapshot)

    def pane(self, selector: SelectorInput[PaneId]) -> "Pane":
        return Pane(
            self._client,
            _selector(selector, PaneId),
            {**self._scope, "screen": self.selector.encode()},
        )

    def list_panes(self) -> List["Pane"]:
        scope = {**self._scope, "screen": self.selector.encode()}
        values = _list_payload(
            self._client._read(Operations.PANE_LIST, scope),
            "panes",
        )
        result: List[Pane] = []
        for value in values:
            snapshot = _pane_snapshot(value)
            result.append(
                Pane(
                    self._client,
                    Selector.by_id(snapshot.id),
                    scope,
                    snapshot,
                )
            )
        return result

    def find_panes_by_name(self, name: str) -> List["Pane"]:
        return [
            item
            for item in self.list_panes()
            if item.snapshot is not None and item.snapshot.name == name
        ]

    def create_pane(
        self,
        options: CreatePaneOptions = CreatePaneOptions(),
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[CreatedPath]:
        scope = {**self._scope, "screen": self.selector.encode()}
        return self._client._created(
            Operations.PANE_CREATE,
            {**scope, **_options(options)},
            idempotency_key,
            expected_revision,
        )

    def rename(
        self, name: Optional[str], *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Screen"]:
        return self._client._mutation_handle(
            Operations.SCREEN_RENAME,
            {**self._params(), "name": name},
            idempotency_key,
            expected_revision,
            _screen_snapshot,
            lambda snapshot: Screen(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def clear_name(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Screen"]:
        return self.rename(
            None,
            idempotency_key=idempotency_key,
            expected_revision=expected_revision,
        )

    def focus(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult["Screen"]:
        return self._client._mutation_handle(
            Operations.SCREEN_FOCUS,
            self._params(),
            idempotency_key,
            expected_revision,
            _screen_snapshot,
            lambda snapshot: Screen(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationReceipt:
        return self._client._mutation(
            Operations.SCREEN_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def export_layout(self) -> LayoutDocument:
        return _layout_document(
            self._client._read(
                Operations.SCREEN_LAYOUT_EXPORT,
                self._params(),
            )
        )

    def undo_layout(
        self,
        *,
        confirm_close: bool = False,
        confirmation_token: Optional[str] = None,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Screen"]:
        if confirm_close and confirmation_token is None:
            raise ValueError(
                "confirmation_token is required when confirm_close is true"
            )
        if confirmation_token is not None:
            if not isinstance(confirmation_token, str):
                raise TypeError("confirmation_token must be a string")
            if (
                not confirmation_token
                or len(confirmation_token.encode("utf-8")) > 128
            ):
                raise ValueError(
                    "confirmation_token must contain 1 to 128 UTF-8 bytes"
                )
        params: Dict[str, Any] = {
            **self._params(),
            "confirm_close": confirm_close,
        }
        if confirmation_token is not None:
            params["confirmation_token"] = confirmation_token
        return self._client._mutation_handle(
            Operations.SCREEN_LAYOUT_UNDO,
            params,
            idempotency_key,
            expected_revision,
            _screen_snapshot,
            lambda snapshot: Screen(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )


class Pane(_Handle[PaneId, PaneSnapshot]):
    _id_type = PaneId
    _selector_key = "pane"
    _get_operation = Operations.PANE_GET
    _decode_snapshot = staticmethod(_pane_snapshot)

    def tab(self, selector: SelectorInput[TabId]) -> "Tab":
        return Tab(
            self._client,
            _selector(selector, TabId),
            {**self._scope, "pane": self.selector.encode()},
        )

    def list_tabs(self) -> List["Tab"]:
        scope = {**self._scope, "pane": self.selector.encode()}
        values = _list_payload(
            self._client._read(Operations.TAB_LIST, scope),
            "tabs",
        )
        result: List[Tab] = []
        for value in values:
            snapshot = _tab_snapshot(value)
            result.append(
                Tab(
                    self._client,
                    Selector.by_id(snapshot.id),
                    scope,
                    snapshot,
                )
            )
        return result

    def find_tabs_by_name(self, name: str) -> List["Tab"]:
        return [
            item
            for item in self.list_tabs()
            if item.snapshot is not None and item.snapshot.name == name
        ]

    def create_terminal_tab(
        self,
        options: CreateTerminalOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[CreatedPath]:
        return self._client._created(
            Operations.TAB_CREATE_TERMINAL,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
        )

    def create_browser_tab(
        self,
        options: CreateBrowserOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[CreatedPath]:
        return self._client._created(
            Operations.TAB_CREATE_BROWSER,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
        )

    def split(
        self,
        options: SplitPaneOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[CreatedPath]:
        return self._client._created(
            Operations.PANE_SPLIT,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
        )

    def rename(
        self, name: Optional[str], *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Pane"]:
        return self._client._mutation_handle(
            Operations.PANE_RENAME,
            {**self._params(), "name": name},
            idempotency_key,
            expected_revision,
            _pane_snapshot,
            lambda snapshot: Pane(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def clear_name(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Pane"]:
        return self.rename(
            None,
            idempotency_key=idempotency_key,
            expected_revision=expected_revision,
        )

    def focus(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult["Pane"]:
        return self._client._mutation_handle(
            Operations.PANE_FOCUS,
            self._params(),
            idempotency_key,
            expected_revision,
            _pane_snapshot,
            lambda snapshot: Pane(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def focus_direction(
        self, direction: Direction, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Pane"]:
        return self._client._mutation_handle(
            Operations.PANE_FOCUS_DIRECTION,
            {**self._params(), "direction": direction},
            idempotency_key,
            expected_revision,
            _pane_snapshot,
            lambda snapshot: Pane(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def neighbor(self, direction: Direction) -> Optional["Pane"]:
        payload = _mapping(
            self._client._read(
                Operations.PANE_NEIGHBOR_GET,
                {**self._params(), "direction": direction},
            ),
            "pane neighbor result",
        )
        _strict_object(payload, ("pane",), "pane neighbor result")
        value = payload.get("pane")
        if value is None:
            return None
        snapshot = _pane_snapshot(value)
        return Pane(
            self._client,
            Selector.by_id(snapshot.id),
            self._scope,
            snapshot,
        )

    def swap(
        self,
        *,
        other_workspace: SelectorInput[WorkspaceId],
        other_screen: SelectorInput[ScreenId],
        other_pane: SelectorInput[PaneId],
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Pane"]:
        return self._client._mutation_handle(
            Operations.PANE_SWAP,
            {
                **self._params(),
                "other_workspace": encode_selector(
                    other_workspace, WorkspaceId
                ),
                "other_screen": encode_selector(other_screen, ScreenId),
                "other_pane": encode_selector(other_pane, PaneId),
            },
            idempotency_key,
            expected_revision,
            _pane_snapshot,
            lambda snapshot: Pane(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def zoom(
        self, enabled: Optional[bool] = None, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Pane"]:
        return self._client._mutation_handle(
            Operations.PANE_ZOOM,
            {
                **self._params(),
                **({"enabled": enabled} if enabled is not None else {}),
            },
            idempotency_key,
            expected_revision,
            _pane_snapshot,
            lambda snapshot: Pane(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def set_split_ratio(
        self,
        split_id: SplitId,
        ratio: float,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Pane"]:
        return self._client._mutation_handle(
            Operations.PANE_SPLIT_RATIO_SET,
            {
                **self._params(),
                "split_id": str(split_id),
                "ratio": ratio,
            },
            idempotency_key,
            expected_revision,
            _pane_snapshot,
            lambda snapshot: Pane(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def set_viewport_width(
        self, columns: int, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Pane"]:
        return self._client._mutation_handle(
            Operations.PANE_VIEWPORT_WIDTH_SET,
            {**self._params(), "columns": columns},
            idempotency_key,
            expected_revision,
            _pane_snapshot,
            lambda snapshot: Pane(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def run(
        self, options: RunOptions, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult[CreatedPath]:
        return self._client._created(
            Operations.PANE_RUN,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
        )

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationReceipt:
        return self._client._mutation(
            Operations.PANE_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            _empty_result,
        )


class Tab(_Handle[TabId, TabSnapshot]):
    _id_type = TabId
    _selector_key = "tab"
    _get_operation = Operations.TAB_GET
    _decode_snapshot = staticmethod(_tab_snapshot)

    def terminal(self, selector: SelectorInput[TerminalId]) -> "Terminal":
        return Terminal(
            self._client,
            _selector(selector, TerminalId),
            {**self._scope, "tab": self.selector.encode()},
        )

    def browser(self, selector: SelectorInput[BrowserId]) -> "Browser":
        return Browser(
            self._client,
            _selector(selector, BrowserId),
            {**self._scope, "tab": self.selector.encode()},
        )

    def rename(
        self, name: Optional[str], *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Tab"]:
        return self._client._mutation_handle(
            Operations.TAB_RENAME,
            {**self._params(), "name": name},
            idempotency_key,
            expected_revision,
            _tab_snapshot,
            lambda snapshot: Tab(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def clear_name(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Tab"]:
        return self.rename(
            None,
            idempotency_key=idempotency_key,
            expected_revision=expected_revision,
        )

    def move(
        self,
        *,
        destination_workspace: SelectorInput[WorkspaceId],
        destination_screen: SelectorInput[ScreenId],
        destination_pane: SelectorInput[PaneId],
        index: int,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Tab"]:
        params = {
            **self._params(),
            "destination_workspace": encode_selector(
                destination_workspace, WorkspaceId
            ),
            "destination_screen": encode_selector(
                destination_screen, ScreenId
            ),
            "destination_pane": encode_selector(
                destination_pane, PaneId
            ),
            "index": index,
        }
        return self._client._mutation_handle(
            Operations.TAB_MOVE,
            params,
            idempotency_key,
            expected_revision,
            _tab_snapshot,
            lambda snapshot: Tab(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def focus(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult["Tab"]:
        return self._client._mutation_handle(
            Operations.TAB_FOCUS,
            self._params(),
            idempotency_key,
            expected_revision,
            _tab_snapshot,
            lambda snapshot: Tab(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationReceipt:
        return self._client._mutation(
            Operations.TAB_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            _empty_result,
        )


class Terminal(_Handle[TerminalId, TerminalSnapshot]):
    _id_type = TerminalId
    _selector_key = "terminal"
    _get_operation = Operations.TERMINAL_GET
    _decode_snapshot = staticmethod(_terminal_snapshot)

    def write(
        self, text: str, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.TERMINAL_INPUT_WRITE,
            {**self._params(), "text": text},
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def write_base64(
        self,
        bytes_base64: str,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.TERMINAL_INPUT_WRITE,
            {**self._params(), "bytes_base64": bytes_base64},
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def keys(
        self,
        options: KeyInputOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.TERMINAL_INPUT_KEYS,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def mouse(
        self,
        options: TerminalMouseOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.TERMINAL_INPUT_MOUSE,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def set_focused(
        self, focused: bool, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.TERMINAL_INPUT_FOCUS,
            {**self._params(), "focused": focused},
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def read_screen(self) -> TerminalScreenResult:
        return _terminal_screen_result(
            self._client._read(
                Operations.TERMINAL_SCREEN_READ,
                self._params(),
            )
        )

    def read_state(self) -> TerminalStateResult:
        return _terminal_state_result(
            self._client._read(
                Operations.TERMINAL_STATE_READ,
                self._params(),
            )
        )

    def read_history(
        self, options: TerminalHistoryOptions = TerminalHistoryOptions()
    ) -> TerminalHistoryResult:
        return _terminal_history_result(
            self._client._read(
                Operations.TERMINAL_HISTORY_READ,
                {**self._params(), **_options(options)},
            )
        )

    def clear_history(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.TERMINAL_HISTORY_CLEAR,
            self._params(),
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def wait(self, options: TerminalWaitOptions) -> TerminalWaitResult:
        params = {**self._params(), "pattern": options.pattern}
        if options.timeout_ms is not None:
            params["timeout_ms"] = _decimal_param(
                options.timeout_ms,
                "timeout_ms",
            )
        return _terminal_wait_result(
            self._client._read(
                Operations.TERMINAL_WAIT,
                params,
                _abandoned_result_decoder=_terminal_wait_result,
            )
        )

    def wait_exit(
        self,
        timeout_ms: Optional[int] = None,
    ) -> TerminalWaitExitResult:
        params = self._params()
        if timeout_ms is not None:
            params["timeout_ms"] = _decimal_param(
                timeout_ms,
                "timeout_ms",
            )
        return _terminal_wait_exit_result(
            self._client._read(
                Operations.TERMINAL_WAIT_EXIT,
                params,
                _abandoned_result_decoder=_terminal_wait_exit_result,
            )
        )

    def copy(self, mode: Optional[str] = None) -> TerminalCopyResult:
        params = self._params()
        if mode is not None:
            params["mode"] = mode
        return _terminal_copy_result(
            self._client._read(Operations.TERMINAL_COPY, params)
        )

    def process(self) -> ProcessInfoResult:
        return _process_info_result(
            self._client._read(
                Operations.TERMINAL_PROCESS_GET,
                self._params(),
            )
        )

    def create_renderer_grant(
        self, *, ttl_ms: Optional[int] = None
    ) -> RendererGrant:
        params = self._params()
        if ttl_ms is not None:
            params["ttl_ms"] = ttl_ms
        return self._client._control(
            Operations.TERMINAL_RENDERER_GRANT_CREATE,
            params,
            _renderer_grant_result,
        )

    def resize_viewer(
        self,
        attachment_lease: str,
        options: ViewerSizeOptions,
    ) -> ViewerResizeResult:
        return self._client._control(
            Operations.TERMINAL_VIEWER_RESIZE,
            {
                **self._params(),
                "attachment_lease": attachment_lease,
                **_options(options),
            },
            _viewer_resize_result,
        )

    def release_viewer(self, attachment_lease: str) -> ViewerReleaseResult:
        return self._client._control(
            Operations.TERMINAL_VIEWER_RELEASE,
            {**self._params(), "attachment_lease": attachment_lease},
            _viewer_release_result,
        )

    def scroll_viewport(
        self, delta_rows: int, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.TERMINAL_VIEWPORT_SCROLL,
            {**self._params(), "delta_rows": delta_rows},
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def move(
        self,
        *,
        destination_workspace: SelectorInput[WorkspaceId],
        destination_screen: SelectorInput[ScreenId],
        destination_pane: SelectorInput[PaneId],
        index: int,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Terminal"]:
        return self._client._mutation_handle(
            Operations.TERMINAL_MOVE,
            {
                **self._params(),
                "destination_workspace": encode_selector(
                    destination_workspace, WorkspaceId
                ),
                "destination_screen": encode_selector(
                    destination_screen, ScreenId
                ),
                "destination_pane": encode_selector(
                    destination_pane, PaneId
                ),
                "index": index,
            },
            idempotency_key,
            expected_revision,
            _terminal_snapshot,
            lambda snapshot: Terminal(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def project(
        self,
        *,
        destination_workspace: SelectorInput[WorkspaceId],
        destination_screen: SelectorInput[ScreenId],
        destination_pane: SelectorInput[PaneId],
        index: int,
        name: Optional[str] = None,
        idempotency_key: Optional[str] = None,
        expected_revision: Optional[str] = None,
    ) -> MutationResult["Tab"]:
        encoded_workspace = encode_selector(destination_workspace, WorkspaceId)
        encoded_screen = encode_selector(destination_screen, ScreenId)
        encoded_pane = encode_selector(destination_pane, PaneId)
        params: Dict[str, Any] = {
            **self._params(),
            "destination_workspace": encoded_workspace,
            "destination_screen": encoded_screen,
            "destination_pane": encoded_pane,
            "index": index,
        }
        if name is not None:
            params["name"] = name
        tab_scope = {
            key: value
            for key, value in self._scope.items()
            if key not in ("workspace", "screen", "pane", "tab")
        }
        tab_scope.update(
            workspace=encoded_workspace,
            screen=encoded_screen,
            pane=encoded_pane,
        )
        return self._client._mutation_handle(
            Operations.TERMINAL_PROJECT,
            params,
            idempotency_key,
            expected_revision,
            _tab_snapshot,
            lambda snapshot: Tab(
                self._client,
                Selector.by_id(snapshot.id),
                tab_scope,
                snapshot,
            ),
        )

    def attach(
        self, options: TerminalAttachOptions = TerminalAttachOptions()
    ) -> ResourceStream[TerminalAttachItem]:
        return self._client._open_stream(
            Operations.TERMINAL_ATTACH,
            {**self._params(), **_options(options)},
            _terminal_attach_item,
        )

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationReceipt:
        return self._client._mutation(
            Operations.TERMINAL_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            _empty_result,
        )


class Browser(_Handle[BrowserId, BrowserSnapshot]):
    _id_type = BrowserId
    _selector_key = "browser"
    _get_operation = Operations.BROWSER_GET
    _decode_snapshot = staticmethod(_browser_snapshot)

    def navigate(
        self, url: str, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Browser"]:
        return self._browser_mutation(
            Operations.BROWSER_NAVIGATE,
            {"url": url},
            idempotency_key,
            expected_revision,
        )

    def back(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult["Browser"]:
        return self._browser_mutation(
            Operations.BROWSER_BACK, {}, idempotency_key, expected_revision
        )

    def forward(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult["Browser"]:
        return self._browser_mutation(
            Operations.BROWSER_FORWARD, {}, idempotency_key, expected_revision
        )

    def reload(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult["Browser"]:
        return self._browser_mutation(
            Operations.BROWSER_RELOAD, {}, idempotency_key, expected_revision
        )

    def activate(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult["Browser"]:
        return self._browser_mutation(
            Operations.BROWSER_ACTIVATE, {}, idempotency_key, expected_revision
        )

    def key(
        self,
        key: str,
        *,
        kind: Optional[str] = None,
        modifiers: Sequence[str] = (),
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationReceipt:
        params: Dict[str, Any] = {
            **self._params(),
            "key": key,
            "modifiers": list(modifiers),
        }
        if kind is not None:
            params["kind"] = kind
        return self._client._mutation(
            Operations.BROWSER_INPUT_KEY,
            params,
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def text(
        self, text: str, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.BROWSER_INPUT_TEXT,
            {**self._params(), "text": text},
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def mouse(
        self,
        options: BrowserMouseOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationReceipt:
        params = _options(options)
        params["pointer_frame_seq"] = _decimal_param(
            options.pointer_frame_seq,
            "pointer_frame_seq",
        )
        return self._client._mutation(
            Operations.BROWSER_INPUT_MOUSE,
            {**self._params(), **params},
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def wheel(
        self,
        delta_x: float,
        delta_y: float,
        *,
        x_px: float,
        y_px: float,
        pointer_frame_seq: int,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.BROWSER_INPUT_WHEEL,
            {
                **self._params(),
                "delta_x": delta_x,
                "delta_y": delta_y,
                "x_px": x_px,
                "y_px": y_px,
                "pointer_frame_seq": _decimal_param(
                    pointer_frame_seq,
                    "pointer_frame_seq",
                ),
            },
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def resize_viewer(
        self,
        attachment_lease: str,
        options: BrowserViewerSizeOptions,
    ) -> BrowserViewerResizeResult:
        return self._client._control(
            Operations.BROWSER_VIEWER_RESIZE,
            {
                **self._params(),
                "attachment_lease": attachment_lease,
                **_options(options),
            },
            _browser_viewer_resize_result,
        )

    def release_viewer(self, attachment_lease: str) -> ViewerReleaseResult:
        return self._client._control(
            Operations.BROWSER_VIEWER_RELEASE,
            {**self._params(), "attachment_lease": attachment_lease},
            _viewer_release_result,
        )

    def attach(
        self, options: BrowserAttachOptions = BrowserAttachOptions()
    ) -> ResourceStream[BrowserAttachItem]:
        return self._client._open_stream(
            Operations.BROWSER_ATTACH,
            {**self._params(), **_options(options)},
            _browser_attach_item,
        )

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationReceipt:
        return self._client._mutation(
            Operations.BROWSER_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def _browser_mutation(
        self,
        operation: Operation,
        params: Mapping[str, Any],
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Browser"]:
        return self._client._mutation_handle(
            operation,
            {**self._params(), **params},
            idempotency_key,
            expected_revision,
            _browser_snapshot,
            lambda snapshot: Browser(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )


class ConnectedClient(_Handle[ConnectedClientId, ClientSnapshot]):
    _id_type = ConnectedClientId
    _selector_key = "client"
    _get_operation = Operations.CLIENT_GET
    _decode_snapshot = staticmethod(_connected_client_snapshot)

    def update_metadata(
        self,
        *,
        name: object = _UNSET,
        kind: object = _UNSET,
    ) -> ClientSnapshot:
        metadata: Dict[str, Any] = {}
        if name is not _UNSET:
            if name is not None and not isinstance(name, str):
                raise TypeError("client name must be a string or None")
            metadata["name"] = name
        if kind is not _UNSET:
            if kind is not None and not isinstance(kind, str):
                raise TypeError("client kind must be a string or None")
            metadata["kind"] = kind
        if not metadata:
            raise ValueError("client metadata update requires name or kind")
        return self._client_control(
            Operations.CLIENT_METADATA_UPDATE,
            {**self._params(), **metadata},
        )

    def clear_name(self) -> ClientSnapshot:
        return self.update_metadata(name=None)

    def set_sizing(
        self,
        terminal: SelectorInput[TerminalId],
        enabled: bool,
        *,
        exclusive: bool = False,
    ) -> ClientSnapshot:
        return self._client_control(
            Operations.CLIENT_SIZING_SET,
            {
                **self._params(),
                "terminal": encode_selector(terminal, TerminalId),
                "enabled": enabled,
                "exclusive": exclusive,
            },
        )

    def release_sizing(
        self, terminal: SelectorInput[TerminalId]
    ) -> ClientSnapshot:
        return self._client_control(
            Operations.CLIENT_SIZING_RELEASE,
            {
                **self._params(),
                "terminal": encode_selector(terminal, TerminalId),
            },
        )

    def set_cell_pixels(
        self,
        width_px: int,
        height_px: int,
    ) -> CellPixelsResult:
        return self._client._control(
            Operations.CLIENT_CELL_PIXELS_SET,
            {
                **self._params(),
                "width_px": width_px,
                "height_px": height_px,
            },
            _cell_pixels_result,
        )

    def detach(self) -> None:
        return self._client._control(
            Operations.CLIENT_DETACH,
            self._params(),
            _empty_result,
        )

    def _client_control(
        self,
        operation: Operation,
        params: Mapping[str, Any],
    ) -> ClientSnapshot:
        snapshot = _connected_client_snapshot(
            self._client._read(operation, params)
        )
        self._snapshot = snapshot
        return snapshot


class PairingRequest(_Handle[PairingRequestId, PairingRequestSnapshot]):
    _id_type = PairingRequestId
    _selector_key = "pairing_request"

    def resolve(
        self,
        decision: Literal["accept", "reject"],
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[PairingResolutionResult]:
        return self._client._mutation(
            Operations.PAIRING_REQUEST_RESOLVE,
            {**self._params(), "decision": decision},
            idempotency_key,
            expected_revision,
            _pairing_resolution,
        )


class FrontendProjection(
    _Handle[ProjectionId, FrontendProjectionSnapshot]
):
    _id_type = ProjectionId
    _selector_key = "frontend_projection"

    def put(
        self,
        projection: Mapping[str, Any],
        *,
        frontend_id: str,
        window_id: str,
        generation: str,
        expected_projection_revision: Optional[str] = None,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["FrontendProjection"]:
        return self._client._mutation_handle(
            Operations.FRONTEND_PROJECTION_PUT,
            {
                **self._params(),
                "frontend_id": frontend_id,
                "window_id": window_id,
                "generation": generation,
                "projection": dict(projection),
                **(
                    {"expected_projection_revision": expected_projection_revision}
                    if expected_projection_revision is not None
                    else {}
                ),
            },
            idempotency_key,
            expected_revision,
            lambda result: _aux_snapshot(
                result,
                "frontend_projection",
                ProjectionId,
                FrontendProjectionSnapshot,
                parent_key="session",
                parent_type=SessionId,
            ),
            lambda snapshot: FrontendProjection(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )


class Notification(_Handle[NotificationId, NotificationSnapshot]):
    _id_type = NotificationId
    _selector_key = "notification"


class Agent(_Handle[AgentId, AgentSnapshot]):
    _id_type = AgentId
    _selector_key = "agent"


class SidebarView(_Handle[SidebarViewId, SidebarViewSnapshot]):
    _id_type = SidebarViewId
    _selector_key = "sidebar_view"
    _get_operation = Operations.SIDEBAR_VIEW_GET
    _decode_snapshot = staticmethod(
        lambda value: _aux_snapshot(
            value,
            "sidebar_view",
            SidebarViewId,
            SidebarViewSnapshot,
            parent_key="session",
            parent_type=SessionId,
        )
    )

    def ensure(
        self,
        options: SidebarEnsureOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["SidebarView"]:
        return self._client._mutation_handle(
            Operations.SIDEBAR_VIEW_ENSURE,
            {**self._scope, **_options(options)},
            idempotency_key,
            expected_revision,
            self._decode_snapshot,
            lambda snapshot: SidebarView(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )

    def attach(self) -> ResourceStream[SidebarAttachItem]:
        return self._client._open_stream(
            Operations.SIDEBAR_VIEW_ATTACH,
            self._params(),
            _sidebar_attach_item,
        )

    def input(
        self,
        options: SidebarInputOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationReceipt:
        return self._client._mutation(
            Operations.SIDEBAR_VIEW_INPUT,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
            _empty_result,
        )

    def resize(
        self,
        options: SidebarResizeOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["SidebarView"]:
        return self._sidebar_mutation(
            Operations.SIDEBAR_VIEW_RESIZE,
            _options(options),
            idempotency_key,
            expected_revision,
        )

    def reload(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["SidebarView"]:
        return self._sidebar_mutation(
            Operations.SIDEBAR_VIEW_RELOAD,
            {},
            idempotency_key,
            expected_revision,
        )

    def _sidebar_mutation(
        self,
        operation: Operation,
        params: Mapping[str, Any],
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["SidebarView"]:
        return self._client._mutation_handle(
            operation,
            {**self._params(), **params},
            idempotency_key,
            expected_revision,
            self._decode_snapshot,
            lambda snapshot: SidebarView(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
        )


__all__ = [
    "Agent",
    "Browser",
    "Client",
    "ConnectedClient",
    "CreatedPath",
    "FrontendProjection",
    "Machine",
    "Notification",
    "PairingRequest",
    "Pane",
    "Screen",
    "Session",
    "SessionCreation",
    "SidebarView",
    "Tab",
    "Terminal",
    "Workspace",
]
