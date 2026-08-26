import Bonsplit
import Foundation

extension DockSplitStore {
    @discardableResult
    func discardPanelOwnershipAndClose(panelId: UUID) -> (any Panel)? {
        let tabIDs = surfaceIdToPanelId.compactMap { tabID, ownedPanelID in
            ownedPanelID == panelId ? tabID : nil
        }
        for tabID in tabIDs {
            surfaceIdToPanelId.removeValue(forKey: tabID)
        }
        return discardPanelStateAndClose(panelId: panelId)
    }

    @discardableResult
    func discardPanelStateAndClose(panelId: UUID) -> (any Panel)? {
        cancelDockReactGrabTask(targetingPanelId: panelId)
        appLinkHandoffCoordinator.cancel(sourcePanelID: panelId)
        panelCancellables[panelId]?.cancel()
        panelCancellables.removeValue(forKey: panelId)
        AppDelegate.shared?.notificationStore?.clearNotifications(
            forTabId: workspaceId,
            surfaceId: panelId
        )
        clearSessionRestoreState(panelId: panelId)
        removeDetachedSurfaceTransfer(forPanelID: panelId)

        guard let panel = panels.removeValue(forKey: panelId) else { return nil }
        if let terminalPanel = panel as? TerminalPanel {
            terminalFontSizeChangeCoordinator?
                .terminalDidLeaveDock(
                    terminalPanel,
                    dock: self
                )
        }
        panel.close()
        return panel
    }
}
