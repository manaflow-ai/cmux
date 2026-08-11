import Bonsplit
import Foundation

extension DockSplitStore {
    @discardableResult
    func discardPanelOwnershipAndClose(panelId: UUID) -> (any Panel)? {
        removeSurfaceMappings(forPanelId: panelId)
        return discardPanelStateAndClose(panelId: panelId)
    }

    @discardableResult
    func discardPanelStateAndClose(panelId: UUID) -> (any Panel)? {
        cancelDockReactGrabTask(targetingPanelId: panelId)
        appLinkHandoffCoordinator.cancel(sourcePanelID: panelId)
        panelCancellables[panelId]?.cancel()
        panelCancellables.removeValue(forKey: panelId)
        resolvedNotificationStore()?.clearNotifications(
            forTabId: workspaceId,
            surfaceId: panelId
        )
        TerminalController.shared.cleanupSurfaceState(surfaceIds: [panelId])
        removeDetachedSurfaceTransfer(forPanelID: panelId)
        clearSessionRestoreState(panelId: panelId)

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
