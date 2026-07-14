import Foundation

enum CmuxRunExecutionTarget: Equatable {
    case newWindow
    case workspace(windowId: UUID, tabManagerIdentity: ObjectIdentifier)
    case surface(
        windowId: UUID,
        workspaceId: UUID,
        paneId: UUID,
        anchorPanelId: UUID?
    )
    case pane(
        windowId: UUID,
        workspaceId: UUID,
        paneId: UUID,
        sourcePanelId: UUID,
        direction: CmuxRunURLDirection
    )
}
