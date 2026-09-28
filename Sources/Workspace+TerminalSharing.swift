import AppKit
import Bonsplit
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation

/// Tab-bar side of shared terminal sizing: the presence accessory on a
/// terminal's tab and the tab context-menu size actions. Every action goes
/// through ``TerminalSharingStore``, the same path as the size panel,
/// shortcut, command palette and socket.
@MainActor
extension Workspace {
    /// Shows or clears the presence accessory on the terminal's tab.
    func updateTerminalSharingPresence(panelId: UUID, snapshot: TerminalSharingSnapshot?) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let presence = snapshot.flatMap { TerminalSharingDisplay(snapshot: $0).tabPresence() }
        bonsplitController.updateTab(tabId, presence: .some(presence))
    }

    /// Handles a size action from a terminal tab's context menu or accessory.
    ///
    /// - Returns: `false` for actions that are not size actions.
    @discardableResult
    func handleTerminalSharingContextAction(_ action: TabContextAction, for tab: Bonsplit.Tab) -> Bool {
        guard let panelId = panelIdFromSurfaceId(tab.id) else { return false }
        let controller = TerminalController.shared
        let store = controller.terminalSharing
        if let mode = action.sizeMode.flatMap({ TerminalSizingMode(rawValue: $0.rawValue) }) {
            if !store.setMode(mode, surfaceID: panelId) { NSSound.beep() }
            if mode == .priority || mode == .fixed {
                // Priority order and the fixed grid are edited in the panel.
                controller.presentTerminalSizePanel(surfaceID: panelId, confirmDisconnectOthers: false)
            }
            return true
        }
        switch action {
        case .sizeToMyWindow:
            if !store.sizeToMe(surfaceID: panelId) { NSSound.beep() }
        case .toggleSizeCountsFromThisDevice:
            if !store.toggleSelfCounts(surfaceID: panelId) { NSSound.beep() }
        case .showSizePanel:
            if !controller.presentTerminalSizePanel(surfaceID: panelId, confirmDisconnectOthers: false) { NSSound.beep() }
        case .disconnectOtherClients:
            if !controller.presentTerminalSizePanel(surfaceID: panelId, confirmDisconnectOthers: true) { NSSound.beep() }
        default:
            return false
        }
        return true
    }
}
