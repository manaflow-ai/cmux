public import Foundation

/// The live anchor-surface facts for the `.anchor` routing branch of
/// `surface.move`, the Sendable twin of the legacy `v2SurfaceMove` anchor
/// lookup.
///
/// When `before_surface_id` / `after_surface_id` is supplied, the app locates
/// the anchor surface, its workspace, pane, and index; the coordinator routes
/// the move into the anchor's window/workspace/pane and derives the destination
/// index from ``ControlSurfaceMovePlan/anchorDestinationIndex(_:)``. A `nil`
/// witness result means any of those lookups failed (legacy "Anchor surface not
/// found").
public struct ControlSurfaceMoveAnchorSnapshot: Sendable, Equatable {
    /// The anchor surface's window (`anchor.windowId`).
    public let windowID: UUID
    /// The anchor surface's workspace (`anchorWorkspace.id`).
    public let workspaceID: UUID
    /// The anchor surface's pane (`anchorPane.id`).
    public let paneID: UUID
    /// The anchor surface's index within its pane (`anchorIndex`).
    public let index: Int

    /// Creates an anchor snapshot.
    ///
    /// - Parameters:
    ///   - windowID: The anchor surface's window.
    ///   - workspaceID: The anchor surface's workspace.
    ///   - paneID: The anchor surface's pane.
    ///   - index: The anchor surface's index within its pane.
    public init(windowID: UUID, workspaceID: UUID, paneID: UUID, index: Int) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.index = index
    }
}
