public import Foundation

/// A read-only snapshot of a workspace's surfaces for the `surface.list` payload.
///
/// Mirrors the legacy `v2SurfaceList` payload: the workspace identity, the ordered
/// surface rows, and the (optional) enclosing window. The coordinator mints the
/// workspace and window refs and turns each ``ControlSurfaceSummary`` into a row.
public struct ControlSurfaceListSnapshot: Sendable, Equatable {
    /// The workspace's identifier.
    public let workspaceID: UUID
    /// The enclosing window's identifier, if it resolved.
    public let windowID: UUID?
    /// The ordered surface rows.
    public let surfaces: [ControlSurfaceSummary]

    /// Creates a surface-list snapshot.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace's identifier.
    ///   - windowID: The enclosing window's identifier, if resolved.
    ///   - surfaces: The ordered surface rows.
    public init(
        workspaceID: UUID,
        windowID: UUID?,
        surfaces: [ControlSurfaceSummary]
    ) {
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.surfaces = surfaces
    }
}
