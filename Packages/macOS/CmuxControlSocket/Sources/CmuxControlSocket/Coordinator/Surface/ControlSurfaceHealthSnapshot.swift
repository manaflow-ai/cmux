public import Foundation

/// A read-only render-health snapshot of a workspace's surfaces for the
/// `surface.health` payload.
///
/// Mirrors the legacy `v2SurfaceHealth` payload: the workspace identity, the
/// ordered health rows, and the (optional) enclosing window. The coordinator mints
/// the workspace and window refs.
public struct ControlSurfaceHealthSnapshot: Sendable, Equatable {
    /// The workspace's identifier.
    public let workspaceID: UUID
    /// The enclosing window's identifier, if it resolved.
    public let windowID: UUID?
    /// The ordered health rows.
    public let surfaces: [ControlSurfaceHealthEntry]

    /// Creates a surface-health snapshot.
    ///
    /// - Parameters:
    ///   - workspaceID: The workspace's identifier.
    ///   - windowID: The enclosing window's identifier, if resolved.
    ///   - surfaces: The ordered health rows.
    public init(
        workspaceID: UUID,
        windowID: UUID?,
        surfaces: [ControlSurfaceHealthEntry]
    ) {
        self.workspaceID = workspaceID
        self.windowID = windowID
        self.surfaces = surfaces
    }
}
