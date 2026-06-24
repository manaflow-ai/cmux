public import Bonsplit
public import Foundation

/// The outcome a browser-pane drop should perform.
public enum BrowserPaneDropAction: Equatable, Sendable {
    /// The drop has no effect (e.g. dropping a pane on itself in the center).
    case noOp
    /// Move the dragged tab into the target pane, optionally creating a split.
    case move(
        tabId: UUID,
        targetWorkspaceId: UUID,
        targetPane: PaneID,
        splitTarget: BrowserPaneSplitTarget?
    )
}
