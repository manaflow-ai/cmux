public import Foundation

/// The outcome of `pane.focus`, preserving the legacy body's distinct failures
/// and the focused identity it echoes back.
///
/// The coordinator validates `pane_id` (returning `invalid_params` itself) and
/// signals `unavailable` when no seam is wired; the seam resolves the workspace
/// and pane, focuses, and returns this resolution.
public enum ControlPaneFocusResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// A TabManager resolved but no workspace did (legacy `not_found` /
    /// "Workspace not found", `data: nil`).
    case workspaceNotFound
    /// The pane id did not match any pane in the workspace (legacy `not_found` /
    /// "Pane not found", `data: {"pane_id": …}`). Carries the unresolved id.
    case paneNotFound(UUID)
    /// The pane was focused. Carries the echoed identity (window may be absent;
    /// workspace and pane are present).
    case focused(windowID: UUID?, workspaceID: UUID, paneID: UUID)
}
