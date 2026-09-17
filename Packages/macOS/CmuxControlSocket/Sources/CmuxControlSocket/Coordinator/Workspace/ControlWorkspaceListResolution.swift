public import Foundation

/// The outcome of `workspace.list`, preserving the legacy body's single failure
/// and the resolved window/workspaces the success echoes back.
///
/// The legacy body resolved a TabManager from the routing params, snapshotted
/// every workspace (in order, marking the selected one), then resolved the
/// owning window id (which may be absent). The coordinator mints the
/// window/workspace refs and writes the per-row `index` / `selected`.
public enum ControlWorkspaceListResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The workspaces were snapshotted. Carries the owning window id (may be
    /// absent, the legacy `v2OrNull` case), the workspace snapshots in order,
    /// and the index of the selected workspace within that list, if any.
    case resolved(
        windowID: UUID?,
        workspaces: [ControlWorkspaceSummary],
        selectedIndex: Int?
    )
}
