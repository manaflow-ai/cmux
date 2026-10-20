import Foundation

// A provider's own login or logout, run where the person can see and answer
// it. Settings is its own window, so a tab opened in the main window's
// focused pane stayed behind it: Re-authenticate and Sign In looked like
// they did nothing (Leo, 2026-10-19: "it only reads").
extension AppServices {
    /// Types `line` and Return into a new terminal tab of the main window's
    /// focused pane and brings that window forward. False without a window.
    @discardableResult
    func runInFrontTerminal(_ line: String) -> Bool {
        guard let controller = windows.active, let pane = controller.focusedPane else { return false }
        pane.newTerminalTab(typing: line + "\r")
        windows.bringToFront(controller)
        return true
    }

    /// Opens `url` in a new browser tab of the main window's focused pane and
    /// brings that window forward. False without a window.
    @discardableResult
    func openInFrontBrowserTab(_ url: URL) -> Bool {
        guard let controller = windows.active, let pane = controller.focusedPane else { return false }
        pane.newBrowserTab(url: url)
        windows.bringToFront(controller)
        return true
    }
}
