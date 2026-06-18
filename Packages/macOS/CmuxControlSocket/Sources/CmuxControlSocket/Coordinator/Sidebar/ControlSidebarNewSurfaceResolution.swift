public import Foundation

/// The outcome of the v1 `new_surface` command.
public enum ControlSidebarNewSurfaceResolution: Sendable, Equatable {
    /// No workspace is selected (legacy default `Failed to create tab`).
    case noTabSelected
    /// The `--pane` argument did not resolve to a pane.
    case paneNotFound
    /// The surface was created.
    case created(UUID)
    /// The create was routed to the remote tmux mirror backing the workspace
    /// (`new-window`); the tab arrives asynchronously via `%window-add`.
    case routedToRemote
    /// Creation failed.
    case failed
}
