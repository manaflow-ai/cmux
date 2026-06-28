public import Foundation

/// The live source-surface facts `surface.move` resolves before routing, the
/// Sendable twin of the legacy `v2SurfaceMove` `app.locateSurface` /
/// `sourceWorkspace` reads.
///
/// The app witness locates the moved surface, its source workspace, its current
/// pane and index, and the default destination pane (`sourcePane ?? focused ??
/// first`); the coordinator seeds the routing defaults (target window/workspace/
/// pane) from this snapshot and the `.source` routing case uses it unchanged.
public struct ControlSurfaceMoveSourceSnapshot: Sendable, Equatable {
    /// The window the source surface lives in (`source.windowId`).
    public let windowID: UUID
    /// The workspace the source surface lives in (`sourceWorkspace.id`).
    public let workspaceID: UUID
    /// The source surface's current pane, or `nil` when it is not in a pane
    /// (`sourceWorkspace.paneId(forPanelId:)`).
    public let paneID: UUID?
    /// The source surface's index within its pane, or `nil`
    /// (`sourceWorkspace.indexInPane(forPanelId:)`).
    public let index: Int?
    /// The default destination pane when no target is requested:
    /// `sourcePane ?? focusedPaneId ?? allPaneIds.first`, or `nil` when the
    /// source workspace has no panes.
    public let defaultDestinationPaneID: UUID?

    /// Creates a source snapshot.
    ///
    /// - Parameters:
    ///   - windowID: The source surface's window.
    ///   - workspaceID: The source surface's workspace.
    ///   - paneID: The source surface's current pane, or `nil`.
    ///   - index: The source surface's index within its pane, or `nil`.
    ///   - defaultDestinationPaneID: The default destination pane, or `nil`.
    public init(
        windowID: UUID,
        workspaceID: UUID,
        paneID: UUID?,
        index: Int?,
        defaultDestinationPaneID: UUID?
    ) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.index = index
        self.defaultDestinationPaneID = defaultDestinationPaneID
    }
}
