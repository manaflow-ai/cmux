import AppKit

extension AppDelegate {
    /// Commits a main-window close without consulting the interactive veto.
    @discardableResult
    func closeMainWindowWithoutInteractiveVeto(_ window: NSWindow) -> Bool {
        guard commitMainWindowClose(window) else { return false }
        WebViewInspectorTeardown.closeAllInspectors(in: window)
        window.close()
        return true
    }
}
