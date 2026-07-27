public import Foundation

/// The outcome of a targeted notification delivery (`notification.create_for_surface`
/// and `notification.create_for_target`), preserving the legacy bodies'
/// failures and the rich identity payload they echo back (workspace, surface,
/// and window refs).
///
/// The two callers differ only in their workspace-not-found error detail:
/// `create_for_surface` returns no data, `create_for_target` returns the
/// requested `workspace_id`. That difference is carried in
/// ``workspaceNotFound(workspaceID:)`` so one resolution type serves both.
public enum ControlNotificationTargetedDeliveryResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// No workspace resolved (legacy `not_found` / "Workspace not found"). The
    /// associated id, when non-`nil`, becomes the error `data.workspace_id`
    /// (`create_for_target`); `nil` yields `data: nil` (`create_for_surface`).
    case workspaceNotFound(workspaceID: UUID?)
    /// The resolved workspace has no such surface (legacy `not_found` /
    /// "Surface not found", `data: {"surface_id": …}`). Carries the surface id.
    case surfaceNotFound(UUID)
    /// The notification was delivered. Carries the resolved workspace id, the
    /// target surface id, and the resolved window id (which may be absent).
    case delivered(workspaceID: UUID, surfaceID: UUID, windowID: UUID?)
}
