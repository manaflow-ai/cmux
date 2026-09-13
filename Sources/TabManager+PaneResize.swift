import Foundation
import CmuxPanes

extension TabManager {
    /// Resize split - not directly supported by bonsplit, but we can adjust divider positions
    func resizeSplit(tabId: UUID, surfaceId: UUID, direction: ResizeDirection, amount: UInt16) -> Bool {
        guard amount > 0,
              let tab = tabs.first(where: { $0.id == tabId }),
              let paneId = tab.paneId(forPanelId: surfaceId) else { return false }

        let paneUUID = paneId.id
        guard tab.bonsplitController.allPaneIds.contains(where: { $0.id == paneUUID }) else {
            return false
        }

        let didResize = paneLayout.resizeSplit(
            in: tab.bonsplitController.treeSnapshot(),
            targetPaneId: paneUUID.uuidString,
            direction: direction,
            amountPixels: amount,
            controller: tab.bonsplitController
        )
        if didResize {
            // Keep the cached layout snapshot and terminal geometry reconciliation
            // in sync for every divider mutation entrypoint.
            tab.didProgrammaticallyChangeSplitGeometry()
        }
        return didResize
    }

    /// Resizes the divider controlling the selected workspace's focused pane.
    @discardableResult
    func resizeFocusedPane(direction: ResizeDirection, amount: UInt16) -> Bool {
        guard let tab = selectedWorkspace,
              let focusedPanelId = tab.focusedPanelId else { return false }
        return resizeSplit(
            tabId: tab.id,
            surfaceId: focusedPanelId,
            direction: direction,
            amount: amount
        )
    }

}
