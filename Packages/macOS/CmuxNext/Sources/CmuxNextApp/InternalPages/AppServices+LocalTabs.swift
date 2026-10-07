import CmuxNextBridge
import CmuxNextDaemon

/// Session-local tabs a pane lists after its daemon and browser tabs:
/// internal pages (`InternalPageTabStore`). Agent chat tabs are store tabs
/// (cmux-tui/spec/commands.md, new-conversation-tab); internal pages are a named gap in
/// plans/cmux-next/ownership.md.
extension AppServices {
    /// Strip items of `paneKey`'s page tabs.
    func localTabItems(in paneKey: String, hiding closed: Set<String>) -> [StripTabItem] {
        pages.tabIDs(in: paneKey).filter { !closed.contains($0) }.map(pages.stripItem)
    }

    /// Closes a page tab. False for any other tab.
    func closeLocalTab(_ key: String) -> Bool {
        guard key.hasPrefix(LocalPageTab.prefix) else { return false }
        pages.close(key)
        cache.release(key)
        return true
    }

    /// Closes the page tabs of panes `store` no longer lists.
    func closeGoneLocalTabs(in store: DaemonStore) {
        pages.closeGonePanes(in: store)
    }
}
