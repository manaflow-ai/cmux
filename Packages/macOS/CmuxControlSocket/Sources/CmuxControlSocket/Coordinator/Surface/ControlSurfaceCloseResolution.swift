public import Foundation

/// The outcome of `surface.close`, preserving the legacy body's distinct failures
/// and the closed identity.
///
/// The coordinator signals `unavailable`; the app resolves the workspace and
/// surface, force-closes it (the socket API is non-interactive), and returns this.
public enum ControlSurfaceCloseResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// No surface resolved and none focused (legacy `not_found` / "No focused
    /// surface").
    case noFocusedSurface
    /// The surface id did not exist (legacy `not_found` / "Surface not found",
    /// `data: {"surface_id": …}`). Carries the surface id.
    case surfaceNotFound(UUID)
    /// The workspace has only one surface left (legacy `invalid_state` / "Cannot
    /// close the last surface").
    case lastSurface
    /// The close call failed (legacy `internal_error` / "Failed to close surface",
    /// `data: {"surface_id": …}`). Carries the surface id.
    case closeFailed(UUID)
    /// The surface was closed. Carries the echoed identity.
    case closed(windowID: UUID?, workspaceID: UUID, surfaceID: UUID)
}
