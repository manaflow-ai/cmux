import CmuxNextDaemon

/// Where a new tab asked for in this pane goes (``DockTabHost``, u9415): every tab opener of a pane
/// asks here first, so no tab enters the Home dock (a pinned column that takes no tabs).
extension PaneController {
    /// The pane a new tab asked for here opens in: this pane when it takes tabs, else the pane
    /// beside the dock. Nil for a dock with nothing beside it (or a neighbour not shown): a
    /// daemon tab may still be asked for here (the daemon opens a new column right of the dock
    /// for a browser or page tab, and refuses anything else), a tab only the app holds may not.
    var tabHost: PaneController? {
        switch daemon.store.tabHost(for: pane.handle) {
        case .takesTabs: self
        case .beside(let host): daemon.store.pane(host).flatMap(services.paneController(for:))
        case .alone: nil
        }
    }

    /// Whether this pane is in a dock that takes no tabs.
    var takesNoTabs: Bool { daemon.store.tabHost(for: pane.handle) != .takesTabs }

    /// ``tabHost`` for a tab the daemon makes: this pane when no host is shown, so the daemon's
    /// own rule (a new column, or a refusal) decides and nothing lands in the dock here.
    var daemonTabHost: PaneController { tabHost ?? self }
}
