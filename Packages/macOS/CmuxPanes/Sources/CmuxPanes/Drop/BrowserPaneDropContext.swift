public import Bonsplit
public import Foundation

/// Identifies the destination pane for a browser-pane drag-and-drop drop.
///
/// Carries the workspace, panel, and pane identity of the pane currently under
/// the drag so routing can decide whether a drop is a no-op (dropping a pane on
/// itself) and which split to create.
public struct BrowserPaneDropContext: Equatable, Sendable {
    /// The workspace that owns the target pane.
    public let workspaceId: UUID
    /// The panel that hosts the target pane.
    public let panelId: UUID
    /// The Bonsplit identity of the target pane.
    public let paneId: PaneID

    /// Creates a drop context for the pane under a browser-pane drag.
    public init(workspaceId: UUID, panelId: UUID, paneId: PaneID) {
        self.workspaceId = workspaceId
        self.panelId = panelId
        self.paneId = paneId
    }
}
