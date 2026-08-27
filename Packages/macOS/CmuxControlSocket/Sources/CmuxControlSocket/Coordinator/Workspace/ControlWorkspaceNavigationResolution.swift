public import Foundation

/// The outcome of `workspace.next` / `workspace.previous` / `workspace.last`,
/// after the coordinator has confirmed routing resolves a TabManager.
///
/// All three legacy bodies share this shape: focus the window, navigate, and on
/// success echo the now-selected workspace + window. The per-method `not_found`
/// message (`"No workspace selected"` vs `"No previous workspace in history"`)
/// is supplied by the coordinator, so the seam only signals which outcome
/// occurred.
public enum ControlWorkspaceNavigationResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// Navigation produced no new selection (legacy `not_found`).
    case notFound
    /// Navigation selected a workspace. Carries the now-selected workspace id and
    /// the owning window id (may be absent).
    case resolved(workspaceID: UUID, windowID: UUID?)
}
