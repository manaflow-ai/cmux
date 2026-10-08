import CmuxNextBridge
import CmuxNextControl
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

    /// Page tabs as the control snapshot lists them (bd cx-5xsi).
    var controlPageFacts: ControlPageFacts {
        ControlPageFacts(appOnlyTabs: { [weak self] pane in self?.controlPageTabs(of: pane) ?? [] },
                         title: { [weak self] page in self?.pages.provider(InternalPageID(rawValue: page))?.title })
    }

    /// `pane`'s app-only page tabs as the control snapshot lists them, the
    /// shown one marked (bd cx-5xsi). The shown tab is the mounted strip's,
    /// else the one a window remembers for the pane.
    func controlPageTabs(of pane: PaneModel) -> [ControlPageTabInfo] {
        let keys = pages.tabIDs(in: pane.id)
        guard !keys.isEmpty else { return [] }
        let shown = paneController(for: pane)?.stripModel.selectedID?.rawValue
            ?? windows.controllers.lazy.compactMap { $0.state.selection.selection(in: pane.id) }.first
        return keys.compactMap { key in
            guard let page = LocalPageTab.page(of: key) else { return nil }
            return ControlPageTabInfo(id: key, page: page.rawValue, title: pages.provider(page)?.title(for: key) ?? "",
                                      isSelected: key == shown)
        }
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
