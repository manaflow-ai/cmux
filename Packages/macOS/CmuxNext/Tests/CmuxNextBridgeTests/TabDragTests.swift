import CmuxNextDaemon
import CmuxNextDesign
import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextBridge

private func context(paneTabs: Int = 3, workspaceTabs: Int = 5, dragged: Int = 1, windowWorkspaces: Int = 1) -> TabDragContext {
    TabDragContext(sourcePaneID: "pane-a", sourcePaneTabCount: paneTabs, sourceWorkspaceID: "ws-1",
                   sourceWorkspaceTabCount: workspaceTabs, draggedTabCount: dragged, sourceWindowWorkspaceCount: windowWorkspaces)
}

private func proposal(_ kind: TabDropKind, ghost: CGRect? = nil) -> TabDropProposal {
    TabDropProposal(kind: kind, highlightFrame: CGRect(x: 0, y: 0, width: 10, height: 10), ghostFrame: ghost)
}

