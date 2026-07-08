public import Foundation

/// The outcome of `surface.focus`, preserving the legacy body's distinct failures
/// and the echoed identity.
///
/// The coordinator validates `surface_id` (returning `invalid_params` itself) and
/// signals `unavailable` when no seam is wired; the seam resolves the workspace,
/// focuses the window/workspace/surface, and returns this resolution.
public enum ControlSurfaceFocusResolution: Sendable, Equatable {
    /// No TabManager resolved (legacy `unavailable` / "TabManager not available").
    case tabManagerUnavailable
    /// A TabManager resolved but no workspace did (legacy `not_found` /
    /// "Workspace not found", `data: nil`).
    case workspaceNotFound
    /// The surface id did not match any surface in the workspace (legacy
    /// `not_found` / "Surface not found", `data: {"surface_id": …}`).
    case surfaceNotFound(UUID)
    /// The surface was focused. Carries the echoed identity (window may be absent).
    case focused(windowID: UUID?, workspaceID: UUID, surfaceID: UUID)
}
