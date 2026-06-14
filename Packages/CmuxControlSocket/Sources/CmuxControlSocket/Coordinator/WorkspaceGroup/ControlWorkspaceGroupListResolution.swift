public import Foundation

/// The outcome of `workspace.group.list`, preserving the legacy body's single
/// failure and the resolved window the success echoes back.
///
/// The legacy body resolved a TabManager from the routing params, snapshotted
/// every workspace group, then resolved the owning window id (which may be
/// absent). The coordinator mints the window/group refs.
public enum ControlWorkspaceGroupListResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The groups were snapshotted. Carries the owning window id (may be absent,
    /// the legacy `v2OrNull` case) and the group snapshots in sidebar order.
    case resolved(windowID: UUID?, groups: [ControlWorkspaceGroupSnapshot])
}
