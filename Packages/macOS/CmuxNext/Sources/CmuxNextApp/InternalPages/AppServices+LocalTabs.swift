import CmuxNextBridge
import CmuxNextControl
import CmuxNextDaemon
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxHomeCore
import CmuxNextAgentActivity
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
        let previews = settings?.snapshot.previewFeatures == true
        return pages.tabIDs(in: paneKey).filter {
            !closed.contains($0) && (previews || !InternalPageTabStore.isPreviewPage(LocalPageTab.page(of: $0)?.rawValue))
        }.map(pages.stripItem)
    }

    /// Page tabs as the control snapshot lists them (bd cx-5xsi).
    var controlPageFacts: ControlPageFacts {
        ControlPageFacts(appOnlyTabs: { [weak self] pane in self?.controlPageTabs(of: pane) ?? [] },
                         title: { [weak self] tab in self?.pages.storeTabItem(tab)?.title },
                         mirroredTabs: { [weak self] pane in self?.tabMirrors[pane.id] ?? [] })
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
    /// The oracle's `tabs` facet: every pane that lists a browser or page tab, as its strip lists
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

    /// The oracle's `agents` facet, over the same trees as the tabs facet: every agent chat tab with
    /// its record's session, acpmux's lane for it (`lane`) and the composer text the tab store keeps for a new chat,
    /// as its sha256; then every Home Messages view (a Home tab, the docked Home, a window's Home top page) and the
    /// conversation it shows, none on New Message or on Channels. Each value read is observed, the Home views'
    /// holders included (their install counters), so `debug.oracle.wait_for` hears it. O(panes + tabs + windows).
    func oracleAgents(lane: (String) -> AgentActivityLane?) -> OracleAgentsFacet.Reading {
        let drafts = madeAgentTabs?.unsentDrafts
        let homeTabs = (pages.provider(.homeTab) as? HomePageTab)?.tabs ?? []
        let docks = (pages.provider(.homeDock) as? HomeDockTab)?.messagesViews ?? []
        let homeViews = Dictionary((homeTabs + docks).map { ($0.key, $0.view) }, uniquingKeysWith: { first, _ in first })
        let homePages: Set<String> = [InternalPageID.homeTab.rawValue, InternalPageID.homeDock.rawValue]
        var reading = OracleAgentsFacet.Reading(sessions: [], home: [])
        for (workspace, _) in machines.allWorkspaces {
            for pane in workspace.screens.flatMap(\.panes) {
                for tab in pane.tabs {
                    if let record = tab.agentSession {
                        reading.sessions.append(Self.oracleSession(tab: tab.id, workspace: workspace.resourceID?.rawValue ?? workspace.id,
                                                                   record: record, lane: record.session.flatMap(lane),
                                                                   draft: drafts?.draft(for: tab.id)))
                    } else if let page = tab.page, homePages.contains(page) {
                        // A Home tab not shown yet has no view: it shows no conversation.
                        let view = pages.storeKey(of: tab.id).flatMap { homeViews[$0] }
                        reading.home.append(OracleAgentsFacet.HomePage(tab: tab.id, conversation: view?.displayedConversation?.rawValue))
                    }
                }
                for key in pages.tabIDs(in: pane.id) where LocalPageTab.page(of: key).map({ homePages.contains($0.rawValue) }) == true {
                    reading.home.append(OracleAgentsFacet.HomePage(tab: key, conversation: homeViews[key]?.displayedConversation?.rawValue))
                }
            }
        }
        for controller in windows.controllers where controller.state.page == .home {
            let page = controller.topPages.homePage
            reading.home.append(OracleAgentsFacet.HomePage(window: controller.state.id, conversation: page?.displayedConversation?.rawValue))
        }
        return reading
    }

    /// One agent chat tab's row: its record's session and harness (else the lane's), acpmux's lane, and `draft`
    /// only as its sha256 (the schema's `derive: sha256`).
    static func oracleSession(tab: String, workspace: String?, record: AgentSessionRef, lane: AgentActivityLane?,
                              draft: String?) -> OracleAgentsFacet.Session {
        let acpmux = lane.map {
            OracleAgentsFacet.Session.Lane(state: $0.state.rawValue, turns: $0.turnCount, pendingPermissions: $0.pendingPermissions)
        }
        return OracleAgentsFacet.Session(tab: tab, workspace: workspace, session: record.session, agent: record.harness ?? lane?.harness,
                                         lane: acpmux, draftSha256: draft.map(OracleValue.sha256))
    }
}
#endif
