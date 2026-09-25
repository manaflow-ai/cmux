public import Foundation

/// The outcome of `surface.reorder`, preserving the legacy body's distinct
/// failures and the reordered identity.
///
/// The coordinator validates `surface_id` and the exactly-one-target rule; the app
/// locates the surface, validates the anchors share its pane, reorders, and returns
/// this resolution.
public enum ControlSurfaceReorderResolution: Sendable, Equatable {
    /// The surface did not resolve (legacy `not_found` / "Surface not found",
    /// `data: {"surface_id": …}`). Carries the surface id.
    case surfaceNotFound(UUID)
    /// An anchor surface was not in the same pane (legacy `invalid_params` /
    /// "Anchor surface must be in the same pane").
    case anchorNotInSamePane
    /// The reorder call failed (legacy `internal_error` / "Failed to reorder
    /// surface").
    case reorderFailed
    /// The surface was reordered. Carries the echoed identity (window and pane are
    /// present from the located surface).
    case reordered(windowID: UUID, workspaceID: UUID, paneID: UUID, surfaceID: UUID)
}
