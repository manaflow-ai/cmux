import AppKit

extension TabManager {
    /// Returns the focused panel if it is a main-area or Dock browser.
    var focusedBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace else { return nil }
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        if let dockBrowser = tab.dockBrowserPanel(owning: window?.firstResponder, in: window) {
            return dockBrowser
        }
        if let panelId = tab.focusedPanelId,
           let browser = tab.panels[panelId] as? BrowserPanel {
            return browser
        }
        return nil
    }
}
