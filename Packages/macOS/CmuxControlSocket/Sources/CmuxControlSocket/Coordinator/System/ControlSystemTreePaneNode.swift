public import Foundation

/// One pane row of the `system.tree` snapshot (the legacy per-pane dictionary
/// of `v2TreeWorkspaceNode`, minus the coordinator-minted refs).
public struct ControlSystemTreePaneNode: Sendable, Equatable {
    /// The pane's identifier.
    public let paneID: UUID
    /// The pane's index in the workspace's pane enumeration.
    public let index: Int
    /// Whether this is the workspace's focused pane.
    public let isFocused: Bool
    /// The pane's surfaces in tab order (panel identifiers).
    public let surfaceIDs: [UUID]
    /// The selected tab's panel identifier, if it resolved.
    public let selectedSurfaceID: UUID?
    /// The pane's surface nodes, pre-sorted by `indexInPane ?? index`.
    public let surfaces: [ControlSystemTreeSurfaceNode]

    /// Creates a pane node.
    ///
    /// - Parameters:
    ///   - paneID: The pane's identifier.
    ///   - index: The pane enumeration index.
    ///   - isFocused: Whether this is the focused pane.
    ///   - surfaceIDs: The pane's surfaces in tab order.
    ///   - selectedSurfaceID: The selected tab's panel identifier.
    ///   - surfaces: The pane's surface nodes.
    public init(
        paneID: UUID,
        index: Int,
        isFocused: Bool,
        surfaceIDs: [UUID],
        selectedSurfaceID: UUID?,
        surfaces: [ControlSystemTreeSurfaceNode]
    ) {
        self.paneID = paneID
        self.index = index
        self.isFocused = isFocused
        self.surfaceIDs = surfaceIDs
        self.selectedSurfaceID = selectedSurfaceID
        self.surfaces = surfaces
    }
}
