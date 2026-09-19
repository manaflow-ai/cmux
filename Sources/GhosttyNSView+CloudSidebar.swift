import AppKit

extension GhosttyNSView {
    func appendFocusInCloudSidebarMenuItem(to menu: NSMenu) {
        guard let panelID = terminalSurface?.id,
              let located = AppDelegate.shared?.locateSurface(surfaceId: panelID),
              let workspace = located.tabManager.tabs.first(where: { $0.id == located.workspaceId }),
              let item = workspace.focusInCloudSidebarMenuItem(panelID: panelID) else { return }
        menu.addItem(.separator())
        menu.addItem(item)
    }
}
