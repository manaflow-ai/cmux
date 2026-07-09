public import Foundation

/// The live workspace facts for the `.workspace` routing branch of
/// `surface.move`, the Sendable twin of the legacy `v2SurfaceMove`
/// `tabManagerFor(tabId:)` lookup.
///
/// When `workspace_id` is supplied (and no anchor/pane), the app locates the
/// workspace's TabManager and default destination pane (`focusedPaneId ??
/// allPaneIds.first`); the coordinator routes the move into the workspace,
/// falling back to the source window when the workspace's window is unknown. A
/// `nil` witness result means the workspace did not resolve (legacy "Workspace
/// not found").
public struct ControlSurfaceMoveWorkspaceSnapshot: Sendable, Equatable {
    /// The workspace's window (`app.windowId(for: tm)`), or `nil` when unknown —
    /// the coordinator falls back to the source window, matching the legacy
    /// `app.windowId(for: tm) ?? targetWindowId`.
    public let windowID: UUID?
    /// The resolved workspace (`ws.id`).
    public let workspaceID: UUID
    /// The default destination pane (`focusedPaneId ?? allPaneIds.first`), or
    /// `nil` when the workspace has no panes.
    public let destinationPaneID: UUID?

    /// Creates a workspace snapshot.
    ///
    /// - Parameters:
    ///   - windowID: The workspace's window, or `nil`.
    ///   - workspaceID: The resolved workspace.
    ///   - destinationPaneID: The default destination pane, or `nil`.
    public init(windowID: UUID?, workspaceID: UUID, destinationPaneID: UUID?) {
        self.windowID = windowID
        self.workspaceID = workspaceID
        self.destinationPaneID = destinationPaneID
    }
}
