public import Foundation

/// The outcome of `workspace.group.focus`, preserving the legacy body's single
/// failure and the focused anchor it echoes back.
///
/// The legacy body focused the owning window, made its TabManager active, then
/// selected the group anchor through `selectWorkspace` (so the selection side
/// effects fire). All of that is app state, so it runs behind the seam; the
/// coordinator mints the anchor workspace ref.
public enum ControlWorkspaceGroupFocusResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// The group or its anchor workspace was not found (legacy `not_found` /
    /// "Group or anchor not found", `data: {"group_id": …}`).
    case notFound
    /// The group's anchor was focused. Carries the anchor workspace id.
    case focused(anchorWorkspaceID: UUID)
}
