public import Foundation

/// The outcome of `file.open` (the legacy `v2FileOpen` main-actor block; the
/// path validation happens in the coordinator).
public enum ControlFileOpenResolution: Sendable, Equatable {
    /// The routed workspace was not found.
    case workspaceNotFound
    /// An explicit `pane_id` did not resolve.
    case requestedPaneNotFound(UUID)
    /// An explicit `surface_id` did not resolve.
    case sourceSurfaceNotFound(UUID)
    /// No destination pane could be resolved at all.
    case paneUnresolved
    /// No surfaces were opened.
    case openFailed
    /// The files opened.
    ///
    /// - Parameters:
    ///   - windowID: The routed window, if it resolved.
    ///   - workspaceID: The enclosing workspace.
    ///   - surfaces: The opened surface rows, in open order (non-empty; the
    ///     last row is the legacy "primary" surface).
    case opened(windowID: UUID?, workspaceID: UUID, surfaces: [ControlFileOpenSurface])
}
