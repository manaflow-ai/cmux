import AppKit

extension AppDelegate {
    /// Commits a main-window close without consulting the interactive veto.
    func closeMainWindowWithoutInteractiveVeto(
        _ window: NSWindow,
        teardownBeforeClose: @MainActor (NSWindow) -> Void = {
            WebViewInspectorTeardown.closeAllInspectors(in: $0)
        }
    ) {
        markMainWindowCloseCommitted(window)
        teardownBeforeClose(window)
        window.close()
    }
}
