import AppKit

extension AppDelegate {
    /// Commits a main-window close without consulting the interactive veto.
    func closeMainWindowWithoutInteractiveVeto(_ window: NSWindow) {
        WebViewInspectorTeardown.closeAllInspectors(in: window)
        window.close()
        // AppKit does not post another will-close notification for a retained
        // NSWindow that is already closed. Commit explicitly so socket/API
        // close requests also clean up any context left by a missed signal.
        commitMainWindowClose(window)
    }
}
