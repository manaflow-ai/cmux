import AppKit

@MainActor
extension AppDelegate {
    @discardableResult
    func openSubrouterPane(tabManager: TabManager) -> Bool {
        guard let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId
                ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }
        return workspace.openOrFocusSubrouterSurface(
            inPane: paneId,
            service: SubrouterAccountService()
        ) != nil
    }

    @objc func performOpenSubrouterPaneMenuItem(_ sender: NSMenuItem) {
        guard let windowId = sender.representedObject as? NSUUID,
              let context = mainWindowContexts.values.first(where: { $0.windowId == windowId as UUID }),
              openSubrouterPane(tabManager: context.tabManager) else {
            NSSound.beep()
            return
        }
    }
}
