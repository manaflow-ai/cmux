import AppKit

extension Workspace {
    func dockBrowserPanel(for panelId: UUID) -> BrowserPanel? {
        _dockSplit?.browserPanel(for: panelId)
    }

    func dockBrowserPanel(owning responder: NSResponder?, in window: NSWindow?) -> BrowserPanel? {
        _dockSplit?.browserPanel(owning: responder, in: window)
    }
}
