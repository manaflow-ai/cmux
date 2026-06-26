public import Bonsplit
public import Foundation

/// Identifies the browser pane that a tab drag is currently hovering over: the
/// owning workspace, the browser panel, and the Bonsplit pane receiving the
/// drop. Carried from the drop-target view into the routing logic so a dropped
/// transfer can be resolved to a concrete `BrowserPaneDropAction`.
public struct BrowserPaneDropContext: Equatable {
    public let workspaceId: UUID
    public let panelId: UUID
    public let paneId: PaneID

    public init(workspaceId: UUID, panelId: UUID, paneId: PaneID) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.paneId = paneId
    }
}
