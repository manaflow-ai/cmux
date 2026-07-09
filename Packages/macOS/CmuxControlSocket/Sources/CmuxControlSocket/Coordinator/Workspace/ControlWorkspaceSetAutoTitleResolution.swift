internal import Foundation

/// The outcome of the `workspace.set_auto_title` apply branch (a non-probe,
/// enabled, non-failure request that targets a workspace title).
///
/// The legacy body resolved a TabManager, then on the main actor found the
/// workspace, set its custom title with the `.auto` source, optionally set a
/// panel title, and — when the workspace title applied — cleared any stale
/// auto-naming failure on the Settings status line. That status-clear side
/// effect stays app-side inside the apply, so the coordinator only shapes the
/// echoed payload.
public enum ControlWorkspaceSetAutoTitleResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// A TabManager resolved but the workspace was not found in it (legacy
    /// `not_found` / "Workspace not found", with the workspace id + ref echoed
    /// by the coordinator).
    case notFound
    /// The title was applied. Carries whether the workspace title actually
    /// changed and the optional panel-apply result (the legacy
    /// `workspace_applied` / `panel_applied` values).
    case applied(workspaceApplied: Bool, panelApplied: Bool?)
}
