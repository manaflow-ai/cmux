import AppKit

extension TabManager {
    /// Returns the focused panel if it is a main-area or Dock browser.
    var focusedBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace else { return nil }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let window, let responder = window.firstResponder {
            if let addressBarPanelId = AppDelegate.shared?.focusedBrowserAddressBarPanelId(),
               browserOmnibarPanelId(for: responder) == addressBarPanelId,
               let browser = tab.browserPanelIncludingDock(for: addressBarPanelId) {
                return browser
            }
            if let context = BrowserWindowPortalRegistry.paneDropContext(owning: responder, in: window),
               context.workspaceId == tab.id,
               let browser = tab.browserPanelIncludingDock(for: context.panelId) {
                return browser
            }
        }
        if let panelId = tab.focusedPanelId,
           let browser = tab.panels[panelId] as? BrowserPanel {
            return browser
        }
        return nil
    }
}
