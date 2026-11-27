public import Foundation

/// The outcome of `pane.join`, preserving the legacy `v2PaneJoin` body's
/// surface-resolution failures and its delegation to the surface-move path.
///
/// The coordinator validates `target_pane_id` (returning `invalid_params`
/// itself); the seam resolves the surface to move (from an explicit
/// `surface_id`, or the selected surface of the source `pane_id`) and forwards
/// to the same surface-move logic `surface.move` uses, returning its result.
public enum ControlPaneJoinResolution: Sendable, Equatable {
    /// A `pane_id` was given without a `surface_id`, but its selected surface
    /// could not be resolved (legacy `not_found` / "Unable to resolve selected
    /// surface in source pane", `data: {"pane_id": …}`). Carries the source
    /// pane id.
    case sourceSurfaceUnresolved(sourcePaneID: UUID)
    /// Neither a `surface_id` nor a `pane_id` with a selected surface was given
    /// (legacy `invalid_params` / "Missing surface_id (or pane_id with selected
    /// surface)", `data: nil`).
    case missingSurface
    /// The surface resolved and the move was attempted; carries the surface-move
    /// result verbatim (the legacy `v2SurfaceMove` return), which the
    /// coordinator returns unchanged.
    case moved(ControlCallResult)
}
