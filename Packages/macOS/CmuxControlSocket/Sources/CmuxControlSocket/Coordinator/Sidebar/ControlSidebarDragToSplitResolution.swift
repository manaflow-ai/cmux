public import Foundation

/// The outcome of the v1 `drag_surface_to_split` fallback path (moving a
/// surface of the selected workspace into a new bonsplit pane).
public enum ControlSidebarDragToSplitResolution: Sendable, Equatable {
    /// No workspace is selected.
    case noTabSelected
    /// The surface argument did not resolve in the selected workspace.
    case surfaceNotFound
    /// Bonsplit refused the split.
    case splitFailed
    /// The surface moved into the new pane.
    case moved(newPaneID: UUID)
}
