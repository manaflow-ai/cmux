internal import Foundation

/// The outcome of the v1 `close_surface` command.
public enum ControlSidebarCloseSurfaceResolution: Sendable, Equatable {
    /// No workspace is selected (legacy default `Failed to close surface`).
    case noTabSelected
    /// The surface argument did not resolve.
    case surfaceNotFound
    /// Refused: the surface is the workspace's last.
    case lastSurface
    /// The surface closed.
    case closed
    /// The close call returned failure.
    case closeFailed
}
