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
    /// Only the authenticated relay owner's identity, with no local topology
    /// or remote connection metadata. This cannot carry a full workspace snapshot.
    case relayWorkspace(id: UUID, title: String)
    /// The authenticated relay owner was no longer active when the read ran.
    /// Keep this distinct from the local TabManager failure so the relay never
    /// exposes an internal implementation name in its product error.
    case relayOwnerUnavailable
    /// The workspaces were snapshotted. Carries the owning window id (may be
    /// absent, the legacy `v2OrNull` case), the workspace snapshots in order,
    /// and the index of the selected workspace within that list, if any.
    case resolved(
        windowID: UUID?,
        workspaces: [ControlWorkspaceSummary],
        selectedIndex: Int?
    )
}
