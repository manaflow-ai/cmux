internal import Foundation

/// The outcome of forwarding a v1 `drag_surface_to_split` stable-ref target to
/// the shared app-side `v2SurfaceSplitOff` body (which also serves the v2
/// `surface.split_off` / `surface.drag_to_split` methods and stays app-side).
public enum ControlSidebarSplitOffOutcome: Sendable, Equatable {
    /// Split-off succeeded; `paneID` is the new pane's UUID string (empty when
    /// the payload had none, matching the legacy bare `OK`).
    case ok(paneID: String)
    /// Split-off failed with the given v2 error message.
    case error(message: String)
}
