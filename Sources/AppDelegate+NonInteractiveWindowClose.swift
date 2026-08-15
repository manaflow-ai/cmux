import AppKit

extension AppDelegate {
    /// Commits a main-window close without consulting the interactive veto.
    func closeMainWindowWithoutInteractiveVeto(_ window: NSWindow) {
        WebViewInspectorTeardown.closeAllInspectors(in: window)
        window.close()
    }
}
