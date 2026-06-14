public import Foundation

/// The outcome of `notification.create`, preserving the legacy body's three
/// distinct failures and the delivered identity it echoes back.
///
/// The legacy body resolved a TabManager from the routing params, then a
/// workspace, optionally validated an explicit `surface_id`, then delivered to
/// the explicit surface or the workspace's focused surface.
public enum ControlNotificationCreateResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not
    /// available").
    case tabManagerUnavailable
    /// A TabManager resolved but no workspace did (legacy `not_found` /
    /// "Workspace not found", `data: nil`).
    case workspaceNotFound
    /// An explicit `surface_id` was given but the resolved workspace has no
    /// such surface (legacy `not_found` / "Surface not found", `data:
    /// {"surface_id": …}`). Carries the unresolved surface id.
    case surfaceNotFound(UUID)
    /// The notification was delivered. Carries the workspace id and the surface
    /// it landed on (the explicit surface, or the workspace's focused surface,
    /// which may be absent).
    case delivered(workspaceID: UUID, surfaceID: UUID?)
}
