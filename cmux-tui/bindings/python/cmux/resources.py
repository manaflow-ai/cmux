from __future__ import annotations

import secrets
import math
import base64
import binascii
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
from .errors import ProtocolError
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
    ProviderActionId,
    ProviderNoticeId,
    ProviderScopeId,
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
    ClientTerminalSize,
    ClientSnapshot,
    Cursor,
    Document,
    ExactCommand,
    ExternalMachineSpecifier,
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
    MutationResult,
    NotificationSnapshot,
    PairingCode,
    PairingRequestSnapshot,
    PaneSnapshot,
    ProviderActionField,
    ProviderActionSnapshot,
    ProviderNoticeKnown,
    ProviderNoticeItem,
    ProviderNoticeSnapshot,
    ProviderScopeSnapshot,
    ProviderCredential,
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
    ScreenSnapshot,
    SessionDelta,
    SessionEvent,
    SessionSnapshotItem,
    SessionSnapshot,
    ShellCommand,
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
    TerminalSnapshot,
    Size,
    PixelSize,
    Unknown,
    WorkspaceSnapshot,
)
from .options import (
    AgentReportOptions,
    BrowserAttachOptions,
    BrowserMouseOptions,
    BrowserViewerSizeOptions,
    CreateBrowserOptions,
    CreateMachineOptions,
    CreatePaneOptions,
    CreateScreenOptions,
    CreateTerminalOptions,
    CreateWorkspaceOptions,
    Direction,
    KeyInputOptions,
    LayoutApplyOptions,
    NotificationOptions,
    ProviderActionOptions,
    RunOptions,
    SessionEventsOptions,
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


def _plain(value: Any) -> Any:
    if isinstance(value, ResourceId):
        return str(value)
    if isinstance(value, Selector):
        return value.encode()
    if isinstance(value, (ExactCommand, ShellCommand)):
        return value.to_params()
    if isinstance(value, ProviderCredential):
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
        "provider_scope_id",
        "deleted",
        "recoverable",
    )
    origin = _required_enum(payload, "origin", ("local", "external"))
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
        provider_scope_id=_optional_resource_id(
            payload,
            "provider_scope_id",
            ProviderScopeId,
        ),
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
    return TerminalSnapshot(
        **_snapshot_fields(
            payload,
            TerminalId,
            ("tab_id", "title", "cwd", "cols", "rows", "running"),
        ),
        tab_id=_required_id(payload, ("tab_id",), TabId),
        title=_required_string(payload, "title"),
        cwd=_optional_present_string(payload, "cwd"),
        cols=_required_positive_uint16(payload, "cols"),
        rows=_required_positive_uint16(payload, "rows"),
        running=_required_bool(payload, "running"),
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
        FrontendProjectionSnapshot: ("session_id", "projection"),
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
        ProviderScopeSnapshot: ("name", "kind", "can_admin", "selected"),
        ProviderActionSnapshot: (
            "provider_scope_id",
            "name",
            "title",
            "enabled",
            "target",
            "destructive",
            "fields",
        ),
        ProviderNoticeSnapshot: (
            "provider_scope_id",
            "level",
            "message",
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
        if "projection" not in payload:
            raise ProtocolError("frontend projection omitted projection")
        arguments["projection"] = payload["projection"]
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
    elif snapshot_type is ProviderScopeSnapshot:
        arguments.update(
            name=_required_string(payload, "name"),
            kind=_required_enum(payload, "kind", ("personal", "team")),
            can_admin=_required_bool(payload, "can_admin"),
            selected=_required_bool(payload, "selected"),
        )
    elif snapshot_type is ProviderActionSnapshot:
        field_values = payload.get("fields")
        if not isinstance(field_values, list):
            raise ProtocolError("provider action fields must be an array")
        decoded_fields: List[ProviderActionField] = []
        for field_value in field_values:
            field_payload = _mapping(field_value, "provider action field")
            _strict_object(
                field_payload,
                (
                    "id",
                    "label",
                    "kind",
                    "required",
                    "max_length",
                    "minimum",
                    "maximum",
                    "placeholder",
                ),
                "provider action field",
            )
            field_id = _required_string(field_payload, "id")
            if not field_id:
                raise ProtocolError("provider action field id must be non-empty")
            kind = _required_enum(
                field_payload,
                "kind",
                ("text", "email", "integer"),
            )
            max_length = (
                _required_int(field_payload, "max_length")
                if "max_length" in field_payload
                else None
            )
            if max_length == 0:
                raise ProtocolError(
                    "provider action field max_length must be positive"
                )
            minimum = (
                _required_int32(field_payload, "minimum")
                if "minimum" in field_payload
                else None
            )
            maximum = (
                _required_int32(field_payload, "maximum")
                if "maximum" in field_payload
                else None
            )
            if (
                minimum is not None
                and maximum is not None
                and minimum > maximum
            ):
                raise ProtocolError(
                    "provider action field minimum exceeds maximum"
                )
            if kind == "integer" and (
                max_length is not None or "placeholder" in field_payload
            ):
                raise ProtocolError(
                    "integer provider action fields cannot use text constraints"
                )
            if kind != "integer" and (
                minimum is not None or maximum is not None
            ):
                raise ProtocolError(
                    "text provider action fields cannot use integer constraints"
                )
            decoded_fields.append(
                ProviderActionField(
                    field_id,
                    _required_string(field_payload, "label"),
                    kind,  # type: ignore[arg-type]
                    _required_bool(field_payload, "required"),
                    max_length,
                    minimum,
                    maximum,
                    _optional_present_string(field_payload, "placeholder"),
                )
            )
        arguments.update(
            provider_scope_id=_required_id(
                payload, ("provider_scope_id",), ProviderScopeId
            ),
            name=_required_string(payload, "name"),
            title=_required_string(payload, "title"),
            enabled=_required_bool(payload, "enabled"),
            target=_required_enum(
                payload,
                "target",
                ("scope", "selected_machine", "selected_workspace"),
            ),
            destructive=_required_bool(payload, "destructive"),
            fields=tuple(decoded_fields),
        )
    elif snapshot_type is ProviderNoticeSnapshot:
        arguments.update(
            provider_scope_id=_required_id(
                payload, ("provider_scope_id",), ProviderScopeId
            ),
            level=_required_enum(
                payload,
                "level",
                ("info", "warning", "error"),
            ),
            message=_required_string(payload, "message"),
        )
    return snapshot_type(**arguments)


def _list_payload(value: Any, key: str) -> List[Any]:
    if not isinstance(value, list):
        raise ProtocolError(f"{key} result must be an array")
    return value


def _pairing_resolution(value: Any) -> PairingRequestSnapshot:
    payload = _mapping(value, "pairing resolution")
    _strict_object(payload, ("pairing_request",), "pairing resolution")
    return _aux_snapshot(
        payload.get("pairing_request"),
        "pairing_request",
        PairingRequestId,
        PairingRequestSnapshot,
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
    "provider_scope",
    "provider_action",
    "provider_notice",
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
        "provider_scope": (
            "provider_scope",
            ProviderScopeId,
            ProviderScopeSnapshot,
        ),
        "provider_action": (
            "provider_action",
            ProviderActionId,
            ProviderActionSnapshot,
        ),
        "provider_notice": (
            "provider_notice",
            ProviderNoticeId,
            ProviderNoticeSnapshot,
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
        "provider_scope": ProviderScopeId,
        "provider_action": ProviderActionId,
        "provider_notice": ProviderNoticeId,
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
            ("kind", "mime_type", "data_base64", "width_px", "height_px"),
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


def _provider_notice_item(value: Any) -> ProviderNoticeItem:
    payload = _mapping(value, "provider notice item")
    kind = payload.get("kind")
    if not isinstance(kind, str):
        raise ProtocolError("provider notice item omitted kind")
    if kind != "notice":
        return Unknown(kind, dict(payload))
    _strict_object(
        payload,
        ("kind", "notice", "sequence"),
        "provider notice item",
    )
    snapshot = _aux_snapshot(
        payload.get("notice"),
        "provider_notice",
        ProviderNoticeId,
        ProviderNoticeSnapshot,
        parent_key="provider_scope",
        parent_type=ProviderScopeId,
    )
    return ProviderNoticeKnown(
        "notice",
        snapshot,
        _required_decimal(payload, "sequence"),
    )


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

    @property
    def closed(self) -> bool:
        return self._connection.closed

    def close(self) -> None:
        self._connection.close()

    def __enter__(self) -> "Client":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

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

    def provider_scope(
        self, selector: SelectorInput[ProviderScopeId]
    ) -> "ProviderScope":
        return ProviderScope(
            self,
            _selector(selector, ProviderScopeId),
            {"machine": Selector.current().encode()},
        )

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

    def create_machine(
        self,
        provider_scope: SelectorInput[ProviderScopeId],
        options: CreateMachineOptions = CreateMachineOptions(),
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Machine"]:
        return self._mutation_handle(
            Operations.MACHINE_CREATE,
            {"provider_scope": encode_selector(provider_scope, ProviderScopeId)},
            idempotency_key,
            expected_revision,
            _machine_snapshot,
            lambda snapshot: Machine(
                self, Selector.by_id(snapshot.id), snapshot=snapshot
            ),
        )

    def list_provider_scopes(self) -> List["ProviderScope"]:
        values = _list_payload(
            self._read(
                Operations.PROVIDER_SCOPE_LIST,
                {"machine": Selector.current().encode()},
            ),
            "provider_scopes",
        )
        result: List[ProviderScope] = []
        for value in values:
            snapshot = _aux_snapshot(
                value,
                "provider_scope",
                ProviderScopeId,
                ProviderScopeSnapshot,
            )
            result.append(
                ProviderScope(
                    self,
                    Selector.by_id(snapshot.id),
                    {"machine": Selector.current().encode()},
                    snapshot=snapshot,
                )
            )
        return result

    def _read(self, operation: Operation, params: Mapping[str, Any]) -> Any:
        if operation.operation_class not in {"read", "connection_control"}:
            raise ValueError(f"{operation.wire_name} is not a read/control operation")
        return self._connection.request(operation.wire_name, params)

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
        raw = self._connection.request(
            operation.wire_name,
            request_params,
            idempotency_key=key,
        )
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
    ) -> Document:
        if operation.operation_class != "connection_control":
            raise ValueError(f"{operation.wire_name} is not connection control")
        value = self._connection.request(operation.wire_name, params)
        return Document(_mapping(value, "control result"))

    def _open_stream(
        self,
        operation: Operation,
        params: Mapping[str, Any],
        decode: Callable[[Any], StreamValueT],
    ) -> ResourceStream[StreamValueT]:
        if operation.operation_class != "stream_open":
            raise ValueError(f"{operation.wire_name} is not a stream operation")
        return self._connection.open_stream(
            operation.wire_name,
            params,
            decode,
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

    def rename(
        self,
        name: str,
        *,
        confirm_close: bool = False,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Machine"]:
        return self._client._mutation_handle(
            Operations.MACHINE_RENAME,
            {**self._params(), "name": name, "confirm_close": confirm_close},
            idempotency_key,
            expected_revision,
            _machine_snapshot,
            lambda snapshot: Machine(
                self._client, Selector.by_id(snapshot.id), snapshot=snapshot
            ),
        )

    def delete(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult["Machine"]:
        return self._client._mutation_handle(
            Operations.MACHINE_DELETE,
            self._params(),
            idempotency_key,
            expected_revision,
            _machine_snapshot,
            lambda snapshot: Machine(
                self._client,
                Selector.by_id(snapshot.id),
                snapshot=snapshot,
            ),
        )

    def restore(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult["Machine"]:
        return self._client._mutation_handle(
            Operations.MACHINE_RESTORE,
            self._params(),
            idempotency_key,
            expected_revision,
            _machine_snapshot,
            lambda snapshot: Machine(
                self._client, Selector.by_id(snapshot.id), snapshot=snapshot
            ),
        )

    def purge(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.MACHINE_PURGE,
            self._params(),
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "machine purge result")),
        )

class Session(_Handle[SessionId, SessionSnapshot]):
    _id_type = SessionId
    _selector_key = "session"
    _get_operation = Operations.SESSION_GET
    _decode_snapshot = staticmethod(_session_snapshot)

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

    def ping(self) -> Document:
        return Document(
            _mapping(
                self._client._read(Operations.SESSION_PING, self._params()),
                "session ping result",
            )
        )

    def events(
        self, options: SessionEventsOptions = SessionEventsOptions()
    ) -> ResourceStream[SessionEvent]:
        return self._client._open_stream(
            Operations.SESSION_EVENTS,
            {**self._params(), **_options(options)},
            _event_item,
        )

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult[Document]:
        return self.shutdown(
            idempotency_key=idempotency_key,
            expected_revision=expected_revision,
        )

    def shutdown(
        self,
        *,
        force: bool = False,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.SESSION_SHUTDOWN,
            {**self._params(), "force": force},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "session shutdown result")),
        )

    def reload_config(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.SESSION_RELOAD_CONFIG,
            self._params(),
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "reload result")),
        )

    def update_terminal_defaults(
        self,
        defaults: Mapping[str, Any],
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.SESSION_TERMINAL_DEFAULTS_UPDATE,
            {**self._params(), **dict(defaults)},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "terminal defaults result")),
        )

    def set_window_title(
        self, title: str, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.WINDOW_TITLE_SET,
            {**self._params(), "title": title},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "title result")),
        )

    def clear_window_title(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.WINDOW_TITLE_CLEAR,
            self._params(),
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "title result")),
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

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.WORKSPACE_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "workspace close result")),
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

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.SCREEN_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "screen close result")),
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
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Screen"]:
        return self._client._mutation_handle(
            Operations.SCREEN_LAYOUT_UNDO,
            {**self._params(), "confirm_close": confirm_close},
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

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.PANE_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "pane close result")),
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

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.TAB_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "tab close result")),
        )


class Terminal(_Handle[TerminalId, TerminalSnapshot]):
    _id_type = TerminalId
    _selector_key = "terminal"
    _get_operation = Operations.TERMINAL_GET
    _decode_snapshot = staticmethod(_terminal_snapshot)

    def write(
        self, text: str, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.TERMINAL_INPUT_WRITE,
            {**self._params(), "text": text},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "terminal write result")),
        )

    def write_base64(
        self,
        bytes_base64: str,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.TERMINAL_INPUT_WRITE,
            {**self._params(), "bytes_base64": bytes_base64},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "terminal write result")),
        )

    def keys(
        self,
        options: KeyInputOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.TERMINAL_INPUT_KEYS,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "terminal key result")),
        )

    def mouse(
        self,
        options: TerminalMouseOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.TERMINAL_INPUT_MOUSE,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "terminal mouse result")),
        )

    def set_focused(
        self, focused: bool, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.TERMINAL_INPUT_FOCUS,
            {**self._params(), "focused": focused},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "terminal focus result")),
        )

    def read_screen(self) -> Document:
        return Document(
            _mapping(
                self._client._read(
                    Operations.TERMINAL_SCREEN_READ,
                    self._params(),
                ),
                "terminal screen",
            )
        )

    def read_state(self) -> Document:
        return Document(
            _mapping(
                self._client._read(
                    Operations.TERMINAL_STATE_READ,
                    self._params(),
                ),
                "terminal state",
            )
        )

    def read_history(
        self, options: TerminalHistoryOptions = TerminalHistoryOptions()
    ) -> Document:
        return Document(
            _mapping(
                self._client._read(
                    Operations.TERMINAL_HISTORY_READ,
                    {**self._params(), **_options(options)},
                ),
                "terminal history",
            )
        )

    def clear_history(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.TERMINAL_HISTORY_CLEAR,
            self._params(),
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "history clear result")),
        )

    def wait(self, options: TerminalWaitOptions) -> Document:
        return Document(
            _mapping(
                self._client._read(
                    Operations.TERMINAL_WAIT,
                    {**self._params(), **_options(options)},
                ),
                "terminal wait result",
            )
        )

    def copy(self, mode: Optional[str] = None) -> Document:
        params = self._params()
        if mode is not None:
            params["mode"] = mode
        return Document(
            _mapping(
                self._client._read(Operations.TERMINAL_COPY, params),
                "terminal copy result",
            )
        )

    def process(self) -> Document:
        return Document(
            _mapping(
                self._client._read(
                    Operations.TERMINAL_PROCESS_GET,
                    self._params(),
                ),
                "terminal process",
            )
        )

    def create_renderer_grant(
        self, *, ttl_ms: Optional[int] = None
    ) -> RendererGrant:
        params = self._params()
        if ttl_ms is not None:
            params["ttl_ms"] = ttl_ms
        result = self._client._control(
            Operations.TERMINAL_RENDERER_GRANT_CREATE,
            params,
        )
        token = result.fields.get("token")
        if not isinstance(token, str):
            raise ProtocolError("renderer grant result omitted token")
        endpoint = result.fields.get("endpoint")
        terminal_id = result.fields.get("terminal_id")
        rights = result.fields.get("rights")
        ttl = result.fields.get("ttl_ms")
        if (
            not isinstance(endpoint, str)
            or not isinstance(terminal_id, str)
            or not isinstance(rights, list)
            or not all(isinstance(right, str) for right in rights)
            or not isinstance(ttl, int)
        ):
            raise ProtocolError("renderer grant result has invalid metadata")
        return RendererGrant(
            token,
            endpoint=endpoint,
            terminal_id=TerminalId(terminal_id),
            rights=rights,
            ttl_ms=ttl,
        )

    def resize_viewer(self, options: ViewerSizeOptions) -> Document:
        return self._client._control(
            Operations.TERMINAL_VIEWER_RESIZE,
            {**self._params(), **_options(options)},
        )

    def release_viewer(self) -> Document:
        return self._client._control(
            Operations.TERMINAL_VIEWER_RELEASE,
            self._params(),
        )

    def scroll_viewport(
        self, delta_rows: int, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.TERMINAL_VIEWPORT_SCROLL,
            {**self._params(), "delta_rows": delta_rows},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "viewport result")),
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

    def attach(
        self, options: TerminalAttachOptions = TerminalAttachOptions()
    ) -> ResourceStream[TerminalAttachItem]:
        return self._client._open_stream(
            Operations.TERMINAL_ATTACH,
            {**self._params(), **_options(options)},
            _terminal_attach_item,
        )

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.TERMINAL_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "terminal close result")),
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
    ) -> MutationResult[Document]:
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
            lambda value: Document(_mapping(value, "browser key result")),
        )

    def text(
        self, text: str, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.BROWSER_INPUT_TEXT,
            {**self._params(), "text": text},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "browser text result")),
        )

    def mouse(
        self,
        options: BrowserMouseOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.BROWSER_INPUT_MOUSE,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "browser mouse result")),
        )

    def wheel(
        self,
        delta_x: float,
        delta_y: float,
        *,
        x_px: float,
        y_px: float,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.BROWSER_INPUT_WHEEL,
            {
                **self._params(),
                "delta_x": delta_x,
                "delta_y": delta_y,
                "x_px": x_px,
                "y_px": y_px,
            },
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "browser wheel result")),
        )

    def resize_viewer(self, options: BrowserViewerSizeOptions) -> Document:
        return self._client._control(
            Operations.BROWSER_VIEWER_RESIZE,
            {**self._params(), **_options(options)},
        )

    def release_viewer(self) -> Document:
        return self._client._control(
            Operations.BROWSER_VIEWER_RELEASE,
            self._params(),
        )

    def attach(
        self, options: BrowserAttachOptions = BrowserAttachOptions()
    ) -> ResourceStream[BrowserAttachItem]:
        return self._client._open_stream(
            Operations.BROWSER_ATTACH,
            {**self._params(), **_options(options)},
            _browser_attach_item,
        )

    def close(self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.BROWSER_CLOSE,
            self._params(),
            idempotency_key,
            expected_revision,
            lambda value: Document(_mapping(value, "browser close result")),
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

    def set_cell_pixels(self, width_px: int, height_px: int) -> Document:
        return self._client._control(
            Operations.CLIENT_CELL_PIXELS_SET,
            {
                **self._params(),
                "width_px": width_px,
                "height_px": height_px,
            },
        )

    def detach(self) -> Document:
        return self._client._control(Operations.CLIENT_DETACH, self._params())

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
    ) -> MutationResult["PairingRequest"]:
        return self._client._mutation_handle(
            Operations.PAIRING_REQUEST_RESOLVE,
            {**self._params(), "decision": decision},
            idempotency_key,
            expected_revision,
            _pairing_resolution,
            lambda snapshot: PairingRequest(
                self._client,
                Selector.by_id(snapshot.id),
                self._scope,
                snapshot,
            ),
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
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["FrontendProjection"]:
        return self._client._mutation_handle(
            Operations.FRONTEND_PROJECTION_PUT,
            {**self._params(), "projection": dict(projection)},
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

    def report(
        self,
        options: AgentReportOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Agent"]:
        return self._client._mutation_handle(
            Operations.AGENT_REPORT,
            {**self._scope, **_options(options)},
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
                self._scope,
                snapshot,
            ),
        )


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
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.SIDEBAR_VIEW_INPUT,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
            lambda value: Document(
                _mapping(value, "sidebar input result")
            ),
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


class ProviderScope(_Handle[ProviderScopeId, ProviderScopeSnapshot]):
    _id_type = ProviderScopeId
    _selector_key = "provider_scope"

    def create_machine(
        self, *, idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None
    ) -> MutationResult["Machine"]:
        return self._client._mutation_handle(
            Operations.MACHINE_CREATE,
            {"provider_scope": self.selector.encode()},
            idempotency_key,
            expected_revision,
            _machine_snapshot,
            lambda snapshot: Machine(
                self._client, Selector.by_id(snapshot.id), snapshot=snapshot
            ),
        )

    def connect_external_machine(
        self,
        specifier: ExternalMachineSpecifier,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Machine"]:
        return self._client._mutation_handle(
            Operations.MACHINE_CONNECT_EXTERNAL,
            {
                "provider_scope": self.selector.encode(),
                "specifier": specifier.take(),
            },
            idempotency_key,
            expected_revision,
            _machine_snapshot,
            lambda snapshot: Machine(
                self._client, Selector.by_id(snapshot.id), snapshot=snapshot
            ),
        )

    def action(
        self, selector: SelectorInput[ProviderActionId]
    ) -> "ProviderAction":
        return ProviderAction(
            self._client,
            _selector(selector, ProviderActionId),
            {**self._scope, "provider_scope": self.selector.encode()},
        )

    def notice(
        self, selector: SelectorInput[ProviderNoticeId]
    ) -> "ProviderNotice":
        return ProviderNotice(
            self._client,
            _selector(selector, ProviderNoticeId),
            {**self._scope, "provider_scope": self.selector.encode()},
        )

    def invoke(
        self,
        action: SelectorInput[ProviderActionId],
        options: ProviderActionOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[Any]:
        return self.action(action).invoke(
            options,
            idempotency_key=idempotency_key,
            expected_revision=expected_revision,
        )

    def notices(
        self, *, cursor: Optional[Cursor] = None
    ) -> ResourceStream[ProviderNoticeItem]:
        params: Dict[str, Any] = {
            **self._scope,
            "provider_scope": self.selector.encode(),
        }
        if cursor is not None:
            params["cursor"] = asdict(cursor)
        return self._client._open_stream(
            Operations.PROVIDER_NOTICE_EVENTS,
            params,
            _provider_notice_item,
        )

    def mark_workspace(
        self,
        workspace: SelectorInput[WorkspaceId],
        managed: bool,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Workspace"]:
        return self._workspace_mutation(
            Operations.PROVIDER_WORKSPACE_MARK,
            workspace,
            {"managed": managed},
            idempotency_key,
            expected_revision,
        )

    def rename_workspace(
        self,
        workspace: SelectorInput[WorkspaceId],
        name: str,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Workspace"]:
        return self._workspace_mutation(
            Operations.PROVIDER_WORKSPACE_RENAME,
            workspace,
            {"name": name},
            idempotency_key,
            expected_revision,
        )

    def close_workspace(
        self,
        workspace: SelectorInput[WorkspaceId],
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[Document]:
        return self._client._mutation(
            Operations.PROVIDER_WORKSPACE_CLOSE,
            {
                **self._scope,
                "provider_scope": self.selector.encode(),
                "session": "current",
                "workspace": encode_selector(workspace, WorkspaceId),
            },
            idempotency_key,
            expected_revision,
            lambda value: Document(
                _mapping(value, "provider workspace close result")
            ),
        )

    def _workspace_mutation(
        self,
        operation: Operation,
        workspace: SelectorInput[WorkspaceId],
        params: Mapping[str, Any],
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult["Workspace"]:
        return self._client._mutation_handle(
            operation,
            {
                **self._scope,
                "provider_scope": self.selector.encode(),
                "session": "current",
                "workspace": encode_selector(workspace, WorkspaceId),
                **params,
            },
            idempotency_key,
            expected_revision,
            _workspace_snapshot,
            lambda snapshot: Workspace(
                self._client,
                Selector.by_id(snapshot.id),
                {},
                snapshot,
            ),
        )


class ProviderAction(_Handle[ProviderActionId, ProviderActionSnapshot]):
    _id_type = ProviderActionId
    _selector_key = "provider_action"

    def invoke(
        self,
        options: ProviderActionOptions,
        *,
        idempotency_key: Optional[str] = None, expected_revision: Optional[str] = None,
    ) -> MutationResult[Any]:
        for name, value in options.parameters.items():
            if not isinstance(name, str):
                raise TypeError("provider action parameter names must be strings")
            if isinstance(value, bool) or not isinstance(value, (str, int)):
                raise TypeError(
                    "provider action values must be strings or int32 values"
                )
            if (
                isinstance(value, int)
                and not -2_147_483_648 <= value <= 2_147_483_647
            ):
                raise ValueError("provider action integer value must be an int32")
        return self._client._mutation(
            Operations.PROVIDER_ACTION_INVOKE,
            {**self._params(), **_options(options)},
            idempotency_key,
            expected_revision,
            lambda value: value,
        )


class ProviderNotice(_Handle[ProviderNoticeId, ProviderNoticeSnapshot]):
    _id_type = ProviderNoticeId
    _selector_key = "provider_notice"

    def acknowledge(self, sequence: str) -> Document:
        if (
            not isinstance(sequence, str)
            or not sequence
            or not sequence.isascii()
            or not sequence.isdecimal()
        ):
            raise ValueError("sequence must be an unsigned decimal string")
        return self._client._control(
            Operations.PROVIDER_NOTICE_ACKNOWLEDGE,
            {**self._params(), "sequence": sequence},
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
    "ProviderAction",
    "ProviderNotice",
    "ProviderScope",
    "Screen",
    "Session",
    "SidebarView",
    "Tab",
    "Terminal",
    "Workspace",
]
