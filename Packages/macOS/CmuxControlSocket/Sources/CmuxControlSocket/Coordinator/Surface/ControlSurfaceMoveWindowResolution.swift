public import Foundation

/// The outcome of the `.window` routing branch of `surface.move`, preserving the
/// legacy `v2SurfaceMove` distinction between a missing window and a window with
/// no selected workspace.
///
/// When `window_id` is supplied (and no anchor/pane/workspace), the app locates
/// the window's TabManager, its selected workspace, and that workspace's default
/// destination pane (`focusedPaneId ?? allPaneIds.first`); the coordinator
/// routes the move into the requested window and the resolved workspace.
public enum ControlSurfaceMoveWindowResolution: Sendable, Equatable {
    /// No TabManager resolved for the window (legacy `not_found` / "Window not
    /// found").
    case windowNotFound
    /// The window has no selected workspace (legacy `not_found` / "Target window
    /// has no selected workspace").
    case noSelectedWorkspace
    /// The window resolved; carries its selected workspace and default
    /// destination pane.
    case resolved(workspaceID: UUID, destinationPaneID: UUID?)
}
