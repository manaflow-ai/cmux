public import Foundation

/// A read-only snapshot of one pane's surfaces for `pane.surfaces`, as the app
/// target exposes it to ``ControlCommandCoordinator``.
///
/// Mirrors the legacy `v2PaneSurfaces` payload (workspace + pane identity, the
/// per-surface rows, and the resolved window). The coordinator shapes the final
/// `JSONValue`, minting workspace/pane/window refs itself.
public struct ControlPaneSurfacesSnapshot: Sendable, Equatable {
    /// The resolved workspace's identifier.
    public let workspaceID: UUID
    /// The pane the surfaces belong to.
    public let paneID: UUID
    /// The window the workspace belongs to, if resolved.
    public let windowID: UUID?
    /// The surfaces in the pane, in tab order.
    public let surfaces: [ControlPaneSurfaceSummary]

    /// Creates a pane-surfaces snapshot.
    ///
    /// - Parameters:
    ///   - workspaceID: The resolved workspace's identifier.
    ///   - paneID: The pane the surfaces belong to.
    ///   - windowID: The window the workspace belongs to, if resolved.
    ///   - surfaces: The surfaces in the pane, in order.
    public init(
        workspaceID: UUID,
        paneID: UUID,
        windowID: UUID?,
        surfaces: [ControlPaneSurfaceSummary]
    ) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.windowID = windowID
        self.surfaces = surfaces
    }
}
