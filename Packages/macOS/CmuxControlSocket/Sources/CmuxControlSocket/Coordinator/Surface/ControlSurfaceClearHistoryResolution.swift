public import Foundation

/// The outcome of `surface.clear_history`, preserving the legacy body's distinct
/// failures and the echoed identity.
///
/// The coordinator signals `unavailable`; the app resolves the workspace and
/// surface, runs the `clear_screen` binding action, and returns this resolution.
public enum ControlSurfaceClearHistoryResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// No workspace resolved (legacy `not_found` / "Workspace not found").
    case workspaceNotFound
    /// A `surface_id` param was present but did not parse (legacy `not_found` /
    /// "Surface not found for the given surface_id").
    case surfaceNotFoundForID
    /// No surface resolved and none focused (legacy `not_found` / "No focused
    /// surface").
    case noFocusedSurface
    /// The resolved surface is not a terminal (legacy `invalid_params` / "Surface
    /// is not a terminal", `data: {"surface_id": …}`). Carries the surface id.
    case surfaceNotTerminal(UUID)
    /// The `clear_screen` binding action is unavailable (legacy `not_supported` /
    /// "clear_screen binding action is unavailable").
    case bindingActionUnavailable
    /// The history was cleared. Carries the echoed identity.
    case cleared(windowID: UUID?, workspaceID: UUID, surfaceID: UUID)
}
