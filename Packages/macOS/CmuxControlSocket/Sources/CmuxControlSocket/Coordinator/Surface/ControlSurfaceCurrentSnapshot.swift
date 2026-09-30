public import Foundation

/// A read-only snapshot of a workspace's current surface for the `surface.current`
/// payload.
///
/// Mirrors the legacy `v2SurfaceCurrent` payload, with the surface/pane/type
/// optional exactly as the legacy `v2OrNull` writes (focus can be transiently nil
/// during startup, so the app falls back to the first ordered panel and may still
/// produce a nil surface). The coordinator mints all refs.
public struct ControlSurfaceCurrentSnapshot: Sendable, Equatable {
    /// The enclosing window's identifier, if it resolved.
    public let windowID: UUID?
    /// The workspace's identifier.
    public let workspaceID: UUID
    /// The current surface's enclosing pane, if it resolved.
    public let paneID: UUID?
    /// The current surface's identifier, if any resolved.
    public let surfaceID: UUID?
    /// The current surface's panel-type raw value, if any resolved.
    public let surfaceTypeRawValue: String?

    /// Creates a current-surface snapshot.
    ///
    /// - Parameters:
    ///   - windowID: The enclosing window's identifier, if resolved.
    ///   - workspaceID: The workspace's identifier.
    ///   - paneID: The current surface's enclosing pane, if resolved.
    ///   - surfaceID: The current surface's identifier, if resolved.
    ///   - surfaceTypeRawValue: The current surface's panel-type raw value.
    public init(
        windowID: UUID?,
        workspaceID: UUID,
        paneID: UUID?,
        surfaceID: UUID?,
        surfaceTypeRawValue: String?
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.surfaceID = surfaceID
        self.surfaceTypeRawValue = surfaceTypeRawValue
    }
}
