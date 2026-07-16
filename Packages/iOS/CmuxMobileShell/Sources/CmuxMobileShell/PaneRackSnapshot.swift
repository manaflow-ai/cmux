public import CmuxMobileShellModel

/// Immutable Pane Rack state for one workspace.
public struct PaneRackSnapshot: Equatable, Sendable {
    /// Workspace represented by the snapshot.
    public var workspaceID: MobileWorkspacePreview.ID
    /// Panes in Mac spatial order, or one synthesized old-Mac pane.
    public var panes: [PaneRackPaneSnapshot]
    /// Phone-local staged pane identifier.
    public var stagedPaneID: String
    /// Whether terminal close intents are supported by the owning Mac.
    public var canCloseTabs: Bool

    /// Creates an immutable Pane Rack snapshot.
    /// - Parameters:
    ///   - workspaceID: Workspace represented by the snapshot.
    ///   - panes: Panes in spatial order.
    ///   - stagedPaneID: Phone-local staged pane identifier.
    ///   - canCloseTabs: Whether terminal close intents are supported.
    public init(
        workspaceID: MobileWorkspacePreview.ID,
        panes: [PaneRackPaneSnapshot],
        stagedPaneID: String,
        canCloseTabs: Bool
    ) {
        self.workspaceID = workspaceID
        self.panes = panes
        self.stagedPaneID = stagedPaneID
        self.canCloseTabs = canCloseTabs
    }
}
