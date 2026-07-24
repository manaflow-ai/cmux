import Bonsplit
import Foundation

enum BrowserPaneDropAction: Equatable {
    case noOp
    case move(
        tabId: UUID,
        targetWorkspaceId: UUID,
        targetPane: PaneID,
        splitTarget: BrowserPaneSplitTarget?
    )
}
