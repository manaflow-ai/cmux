import Foundation

/// Back after a relaunch reaches Chromium's own entries (audit 4, P7): a tab whose saved record has no engine
/// state it may use gets its saved web entries back by address and title (``BrowserRestoreState/chromiumEntries(_:)``),
/// so Back steps through Chromium's real list instead of reloading the saved page over the one entry it had.
extension CEFTab {
    /// Before the browser exists: it is made with no address and restores `session`, loading its current entry.
    /// False, and the tab loads its address as before, on a fork without the call or with nothing to give.
    @discardableResult
    func restoreEntriesOnCreation(_ session: BrowserSavedSession) -> Bool {
        guard browserID == nil, !isCreationPending, pendingRestore == nil, runtime.shim?.tabRestoreEntries != nil,
              session.entries.count > 1, session.entries.indices.contains(session.current) else { return false }
        pendingEntries = session
        return true
    }

    /// The browser exists (``attach(browser:)``): the entries go one way, as the navigation restore does (its
    /// answer is a stand-in in host mode). One-way, as Chrome's NavigationController::Restore.
    func sendPendingEntries(browser: Int32) {
        guard let session = pendingEntries else { return }
        pendingEntries = nil
        _ = runtime.shim?.tabRestoreEntries?(browser, session.entries, current: Int32(session.current))
        host.lifecycleTrace.record(id, "restore-entries sent \(session.entries.count)")
    }
}
