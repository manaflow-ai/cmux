public import Foundation

/// The outcome of `surface.trigger_flash`, preserving the legacy body's distinct
/// failures and the echoed identity.
///
/// The coordinator signals `unavailable`; the app resolves the workspace and
/// surface, focuses the window/workspace, triggers the focus flash, and returns
/// this resolution.
public enum ControlSurfaceTriggerFlashResolution: Sendable, Equatable {
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
    /// The flash was triggered. Carries the echoed identity.
    case flashed(windowID: UUID?, workspaceID: UUID, surfaceID: UUID)
}
