import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextBrowser
import CmuxNextBrowserTabs
import CmuxNextOracle
#endif

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
                         title: { [weak self] tab in self?.pages.storeTabItem(tab)?.title })
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

#if DEBUG || CMUX_BENCH_HOOKS
extension AppServices {
    /// The oracle's `tabs` facet (p15-oracle-037): every pane that lists a browser or page tab, as its strip lists
    /// them (`PaneController.structure`): daemon tabs, then its window's session-local browser tabs, then internal
    /// page tabs, less the tabs the strip leaves out (`stripHidden`). A pane no window mounts lists what its strip
    /// would: no tab hidden, the local tabs of the window that holds them. Shown tab as `controlPageTabs` picks it.
    /// Model values only, O(panes + tabs).
    ///
    /// The page table is not observable: reading `pageInstalls` makes a `wait_for` read again when a page is
    /// installed or replaced (a CEF page made later, a stand-in swapped for the live page); the live page's own
    /// state is observable.
    func oracleTabPanes() -> [OracleTabsFacet.Pane] {
        oracleTabPanes(strip: paneController(for:), windows: windows.controllers.map(\.state))
    }

    /// - Parameters:
    ///   - strip: The pane's mounted strip, nil when no window mounts it.
    ///   - windows: Every window's state, front first (session-local tabs and remembered selections).
    func oracleTabPanes(strip mounted: (PaneModel) -> PaneController?, windows states: [WindowState]) -> [OracleTabsFacet.Pane] {
        _ = cache.pageInstalls.revision
        var panes: [OracleTabsFacet.Pane] = []
        for (workspace, _) in machines.allWorkspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                let strip = mounted(pane)
                let hidden = strip?.stripHidden ?? []
                let locals: [LocalBrowserTab] = if let strip { strip.state?.localBrowserTabs[pane.id] ?? [] } else {
                    states.lazy.map { $0.localBrowserTabs[pane.id] }.first(where: { !$0.isEmpty }) ?? []
                }
                var tabs = pane.tabs.filter { !hidden.contains($0.id) }.compactMap(oracleTab)
                for local in locals where !hidden.contains(local.id) {
                    tabs.append(.browser(id: local.id, pinned: false, page: cache.existingBrowser(local.id)?.tab,
                                         record: .init(url: local.url?.absoluteString), hibernated: cache.dormantTabs.contains(local.id)))
                }
                for key in pages.tabIDs(in: pane.id) where !hidden.contains(key) {
                    guard let page = LocalPageTab.page(of: key) else { continue }
                    tabs.append(.page(id: key, page: page.rawValue, title: pages.provider(page)?.title(for: key)))
                }
                guard !tabs.isEmpty else { continue }
                let selected = strip?.stripModel.selectedID?.rawValue
                    ?? states.lazy.compactMap { $0.selection.selection(in: pane.id) }.first
                panes.append(OracleTabsFacet.Pane(id: pane.id, selected: selected, tabs: tabs))
            }
        }
        return panes
    }

    /// A daemon tab as the facet lists it: a store page tab or a browser tab; nil for any other kind.
    private func oracleTab(_ tab: TabModel) -> OracleTabsFacet.Tab? {
        if let page = tab.page { return .page(id: tab.id, page: page, title: pages.storeTabItem(tab)?.title) }
        guard tab.kind == .browser else { return nil }
        let record = OracleTabsFacet.Tab.Record(url: tab.url, title: tab.title.isEmpty ? nil : tab.title, zoom: tab.zoom,
                                                engine: tab.browserEngine)
        return .browser(id: tab.id, pinned: tab.pinned, page: cache.existingBrowser(tab.id)?.tab, record: record,
                        hibernated: cache.dormantTabs.contains(tab.id))
    }
}
#endif
