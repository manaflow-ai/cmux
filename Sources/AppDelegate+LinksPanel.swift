import AppKit
import Foundation

extension AppDelegate {
    @discardableResult
    func openLinksPanelForFocusedWorkspace(for tabManager: TabManager?) -> Bool {
        guard let workspace = tabManager?.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }
        return workspace.openOrFocusWorkspaceLinksSurface(inPane: paneId, focus: true) != nil
    }
}
