import CmuxNextAccounts

// A provider's own login or logout, run where the person can see and answer
// it. Settings is its own window, so a tab opened in the main window's
// focused pane stayed behind it: Re-authenticate and Sign In looked like
// they did nothing (Leo, 2026-10-19: "it only reads").
extension AppServices {
    /// Opens a tab in the main window's focused pane with `open` and brings
    /// that window forward. Accounts reads this Mac's sign-ins, so the tab
    /// is on this Mac: the focused pane when it is local, else another local
    /// pane of the window. False without one.
    @discardableResult
    func inFrontPane(_ open: (PaneController) -> Void) -> Bool {
        guard let controller = windows.active, let pane = LocalPanePick(focused: controller.focusedPane, others: controller.content.map { Array($0.panes.values) } ?? [], isLocal: { $0.daemon.isLocal }).pane else { return false }
        open(pane)
        windows.bringToFront(controller)
        return true
    }
}
