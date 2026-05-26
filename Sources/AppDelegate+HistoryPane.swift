import AppKit

extension AppDelegate {
    @discardableResult
    func openHistoryPane(
        preferredTabManager: TabManager? = nil,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        let manager = preferredTabManager
            ?? activeTabManagerForCommands(preferredWindow: preferredWindow ?? NSApp.keyWindow ?? NSApp.mainWindow)
        guard let workspace = manager?.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }

        workspace.clearSplitZoom()
        return workspace.openOrFocusRightSidebarToolSurface(
            inPane: paneId,
            mode: .history,
            focus: true
        ) != nil
    }
}
