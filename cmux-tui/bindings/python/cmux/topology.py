from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any, Dict, List, Optional
from uuid import UUID


CANONICAL_TOPOLOGY_SNAPSHOT_CAPABILITY = "canonical-topology-snapshot-v1"
STABLE_ENTITY_UUID_CAPABILITY = "stable-entity-uuid-v1"
TOPOLOGY_RESUME_CAPABILITY = "topology-resume-v1"
TOPOLOGY_V8_CAPABILITIES = (
    CANONICAL_TOPOLOGY_SNAPSHOT_CAPABILITY,
    STABLE_ENTITY_UUID_CAPABILITY,
    TOPOLOGY_RESUME_CAPABILITY,
)


@dataclass(frozen=True)
class TopologyAuthority:
    daemon_instance_id: UUID
    session_id: UUID


@dataclass(frozen=True)
class TopologyCursor:
    daemon_instance_id: UUID
    session_id: UUID
    revision: int

    @property
    def authority(self) -> TopologyAuthority:
        return TopologyAuthority(self.daemon_instance_id, self.session_id)


@dataclass(frozen=True)
class CanonicalLayout:
    type: str
    pane: Optional[int] = None
    pane_uuid: Optional[UUID] = None
    dir: Optional[str] = None
    ratio: Optional[float] = None
    a: Optional["CanonicalLayout"] = None
    b: Optional["CanonicalLayout"] = None


@dataclass(frozen=True)
class CanonicalTab:
    id: int
    uuid: UUID
    kind: str
    name: Optional[str]


@dataclass(frozen=True)
class CanonicalPane:
    id: int
    uuid: UUID
    name: Optional[str]
    tabs: List[CanonicalTab]


@dataclass(frozen=True)
class CanonicalScreen:
    id: int
    uuid: UUID
    name: Optional[str]
    layout: CanonicalLayout
    panes: List[CanonicalPane]


@dataclass(frozen=True)
class CanonicalWorkspace:
    id: int
    uuid: UUID
    name: str
    screens: List[CanonicalScreen]


@dataclass(frozen=True)
class CanonicalTopology:
    workspaces: List[CanonicalWorkspace]


@dataclass(frozen=True)
class TopologySnapshot:
    daemon_instance_id: UUID
    session_id: UUID
    revision: int
    topology: CanonicalTopology

    @property
    def cursor(self) -> TopologyCursor:
        return TopologyCursor(self.daemon_instance_id, self.session_id, self.revision)


@dataclass(frozen=True)
class TopologyTargets:
    workspaces: List[UUID]
    screens: List[UUID]
    panes: List[UUID]
    surfaces: List[UUID]


class TopologyOperation(str, Enum):
    WORKSPACE_CREATED = "workspace-created"
    SCREEN_CREATED = "screen-created"
    PANE_SPLIT = "pane-split"
    SURFACE_ATTACHED = "surface-attached"
    SURFACE_CLOSED = "surface-closed"
    PANE_CLOSED = "pane-closed"
    SCREEN_CLOSED = "screen-closed"
    WORKSPACE_CLOSED = "workspace-closed"
    WORKSPACE_RENAMED = "workspace-renamed"
    SCREEN_RENAMED = "screen-renamed"
    PANE_RENAMED = "pane-renamed"
    SURFACE_RENAMED = "surface-renamed"
    SPLIT_RATIO_CHANGED = "split-ratio-changed"
    PANES_SWAPPED = "panes-swapped"
    LAYOUT_APPLIED = "layout-applied"
    TAB_MOVED = "tab-moved"
    WORKSPACE_MOVED = "workspace-moved"


@dataclass(frozen=True)
class TopologyDelta:
    daemon_instance_id: UUID
    session_id: UUID
    base_revision: int
    revision: int
    operation: TopologyOperation
    targets: TopologyTargets
    replacement: CanonicalTopology


class TopologyResnapshotReason(str, Enum):
    STALE_DAEMON = "stale-daemon"
    STALE_SESSION = "stale-session"
    REVISION_AHEAD = "revision-ahead"
    HISTORY_GAP = "history-gap"
    REPLAY_TOO_LARGE = "replay-too-large"
    SLOW_CONSUMER = "slow-consumer"


@dataclass(frozen=True)
class TopologyResnapshotRequired:
    daemon_instance_id: UUID
    session_id: UUID
    current_revision: Optional[int]
    reason: TopologyResnapshotReason


@dataclass(frozen=True)
class TopologySubscribed:
    daemon_instance_id: UUID
    session_id: UUID
    from_revision: int
    current_revision: int
    replayed: int


def parse_topology_snapshot(value: Dict[str, Any]) -> TopologySnapshot:
    return TopologySnapshot(
        daemon_instance_id=_uuid(value["daemon_instance_id"]),
        session_id=_uuid(value["session_id"]),
        revision=_revision(value["revision"]),
        topology=parse_canonical_topology(value["topology"]),
    )


def parse_topology_subscribed(value: Dict[str, Any]) -> TopologySubscribed:
    return TopologySubscribed(
        daemon_instance_id=_uuid(value["daemon_instance_id"]),
        session_id=_uuid(value["session_id"]),
        from_revision=_revision(value["from_revision"]),
        current_revision=_revision(value["current_revision"]),
        replayed=_revision(value["replayed"]),
    )


def parse_topology_delta(value: Dict[str, Any]) -> TopologyDelta:
    targets = value.get("targets", {})
    return TopologyDelta(
        daemon_instance_id=_uuid(value["daemon_instance_id"]),
        session_id=_uuid(value["session_id"]),
        base_revision=_revision(value["base_revision"]),
        revision=_revision(value["revision"]),
        operation=TopologyOperation(value["operation"]),
        targets=TopologyTargets(
            workspaces=_uuid_list(targets.get("workspaces", [])),
            screens=_uuid_list(targets.get("screens", [])),
            panes=_uuid_list(targets.get("panes", [])),
            surfaces=_uuid_list(targets.get("surfaces", [])),
        ),
        replacement=parse_canonical_topology(value["replacement"]),
    )


def parse_resnapshot_required(value: Dict[str, Any]) -> TopologyResnapshotRequired:
    current = value.get("current_revision")
    return TopologyResnapshotRequired(
        daemon_instance_id=_uuid(value["daemon_instance_id"]),
        session_id=_uuid(value["session_id"]),
        current_revision=None if current is None else _revision(current),
        reason=TopologyResnapshotReason(value["reason"]),
    )


def validate_topology_delta(
    cursor: TopologyCursor,
    delta: TopologyDelta,
) -> Optional[TopologyResnapshotRequired]:
    if delta.daemon_instance_id != cursor.daemon_instance_id:
        reason = TopologyResnapshotReason.STALE_DAEMON
    elif delta.session_id != cursor.session_id:
        reason = TopologyResnapshotReason.STALE_SESSION
    elif delta.base_revision != cursor.revision or delta.revision != delta.base_revision + 1:
        reason = TopologyResnapshotReason.HISTORY_GAP
    else:
        return None
    return TopologyResnapshotRequired(
        daemon_instance_id=delta.daemon_instance_id,
        session_id=delta.session_id,
        current_revision=delta.revision,
        reason=reason,
    )


def parse_canonical_topology(value: Dict[str, Any]) -> CanonicalTopology:
    return CanonicalTopology(
        workspaces=[_parse_workspace(item) for item in value.get("workspaces", [])]
    )


def _parse_workspace(value: Dict[str, Any]) -> CanonicalWorkspace:
    return CanonicalWorkspace(
        id=_revision(value["id"]),
        uuid=_uuid(value["uuid"]),
        name=str(value["name"]),
        screens=[_parse_screen(item) for item in value.get("screens", [])],
    )


def _parse_screen(value: Dict[str, Any]) -> CanonicalScreen:
    return CanonicalScreen(
        id=_revision(value["id"]),
        uuid=_uuid(value["uuid"]),
        name=value.get("name"),
        layout=_parse_layout(value["layout"]),
        panes=[_parse_pane(item) for item in value.get("panes", [])],
    )


def _parse_layout(value: Dict[str, Any]) -> CanonicalLayout:
    if value.get("type") == "leaf":
        return CanonicalLayout(
            type="leaf",
            pane=_revision(value["pane"]),
            pane_uuid=_uuid(value["pane_uuid"]),
        )
    if value.get("type") == "split":
        return CanonicalLayout(
            type="split",
            dir=str(value["dir"]),
            ratio=float(value["ratio"]),
            a=_parse_layout(value["a"]),
            b=_parse_layout(value["b"]),
        )
    raise ValueError(f"invalid canonical layout type {value.get('type')!r}")


def _parse_pane(value: Dict[str, Any]) -> CanonicalPane:
    return CanonicalPane(
        id=_revision(value["id"]),
        uuid=_uuid(value["uuid"]),
        name=value.get("name"),
        tabs=[_parse_tab(item) for item in value.get("tabs", [])],
    )


def _parse_tab(value: Dict[str, Any]) -> CanonicalTab:
    kind = str(value["kind"])
    if kind not in ("pty", "browser"):
        raise ValueError(f"invalid canonical tab kind {kind!r}")
    return CanonicalTab(
        id=_revision(value["id"]),
        uuid=_uuid(value["uuid"]),
        kind=kind,
        name=value.get("name"),
    )


def _uuid(value: Any) -> UUID:
    parsed = UUID(str(value))
    if str(parsed) != value:
        raise ValueError(f"UUID must use lowercase hyphenated form: {value!r}")
    return parsed


def _uuid_list(values: List[Any]) -> List[UUID]:
    return [_uuid(value) for value in values]


def _revision(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"expected non-negative integer, got {value!r}")
    return value
