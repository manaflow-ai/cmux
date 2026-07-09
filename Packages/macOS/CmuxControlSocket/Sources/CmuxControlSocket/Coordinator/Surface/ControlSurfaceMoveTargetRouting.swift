public import Foundation

/// Which target the `surface.move` precedence selects for the moved surface.
///
/// The legacy `v2SurfaceMove` body chose its destination in a fixed precedence:
/// an `anchor` surface (`before_surface_id` / `after_surface_id`) wins, then an
/// explicit `pane_id`, then `workspace_id`, then `window_id`, and finally the
/// surface's own `source` workspace when nothing was requested. ``ControlSurfaceMovePlan``
/// computes this purely from the parsed params; the app then performs the live
/// lookup the chosen case names (locate the anchor surface, the pane, the
/// workspace, or the window) inside `v2MainSync`.
public enum ControlSurfaceMoveTargetRouting: Sendable, Equatable {
    /// Route relative to an anchor surface (highest precedence). Carries the
    /// anchor `surface_id`; the destination index comes from
    /// ``ControlSurfaceMovePlan/anchorDestinationIndex(_:)``.
    case anchor(surfaceID: UUID)
    /// Route into an explicit pane (`pane_id`).
    case pane(UUID)
    /// Route into an explicit workspace (`workspace_id`).
    case workspace(UUID)
    /// Route into an explicit window (`window_id`), landing on its selected
    /// workspace.
    case window(UUID)
    /// No target requested: move within the surface's own source workspace.
    case source
}
