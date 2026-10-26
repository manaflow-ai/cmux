import AppKit
import CmuxNextBridge
import CmuxNextHibernation
import CmuxNextPages

extension InternalPageTabStore {
    /// The catalog show action of every page (`openSettings`,
    /// `openDebugSettings`, `appStore.show`): selects `page`'s tab in
    /// `window`, else opens one after the focused pane's selected tab: a
    /// store tab where the pane's daemon holds page tabs, else an app-only one.
    /// A user run selects and focuses it, and a window on a top page leaves
    /// the page so the tab shows (SIDEBAR-SELECTION-ONE-MODEL); automation
    /// (`ActionInvocation.allowsViewChange` false) opens it without changing
    /// the selection, focus or page (under a page, in the parked workspace).
    /// A user run where a tab would not be seen (Home stands for the hidden
    /// home workspace, or the workspace has no pane) shows the page as the
    /// window's top page instead, and a page already shown on top shows
    /// again (cx-cmge7: What's New on Home opened a tab in the hidden home
    /// workspace and nothing showed).
    /// Returns the tab's (or top page's) view, or nil when nothing can hold it.
    @discardableResult
    func show(_ page: InternalPageID, in window: WindowController?, focus: Bool) -> InternalPageView? {
        guard let window else { return nil }
        if focus, window.shownTopPage == .page(page) || !window.holdsVisiblePageTab {
            return showTopPage(page, in: window)
        }
        if focus { window.leaveTopPage() }
        guard let content = window.workspaceContent else { return nil }
        // The model's panes: a workspace parked under a top page lays out nothing, so its view's
        // panes may lack one the daemon added or still hold one it closed.
        let panes = content.modelPanes
        let daemon = content.daemon
        for pane in panes {
            guard let tab = pane.tabs.first(where: { $0.page == page.rawValue }) else { continue }
            if focus, let controller = content.controller(for: pane) { reveal(tab.id, in: controller) }
            return view(forStoreTab: tab, in: daemon.store, local: daemon.isLocal, window: window)
        }
        if let found = tab(of: page, inPanes: panes.map(\.id)) {
            if focus, let controller = panes.first(where: { $0.id == found.pane }).flatMap(content.controller(for:)) {
                reveal(found.key, in: controller)
            }
            return view(for: found.key)
        }
        return openNew(page, in: window, focus: focus)
    }

    /// One more tab of `page` after `window`'s focused pane's selected tab,
    /// even when the window lists one already (`home.tab`): a store tab
    /// where the pane's daemon holds page tabs, else an app-only one. Focus
    /// as in ``show(_:in:focus:)``. Nil when `window` has no pane.
    @discardableResult
    func openNew(_ page: InternalPageID, in window: WindowController?, focus: Bool) -> InternalPageView? {
        guard let window else { return nil }
        if focus { window.leaveTopPage() }
        // Never in a dock (the docked Home, a chat dock): beside it. Chosen from the model: a
        // workspace parked under a top page shows nothing of a pane the daemon changed meanwhile.
        guard let content = window.workspaceContent, let model = content.pageTabModelPane else { return nil }
        let pane = content.controller(for: model)
        if let view = openStoreTab(page, in: model, of: content.daemon, services: window.services, controller: pane,
                                   window: window, focus: focus) { return view }
        let key = open(page, in: model.id, of: content.daemon.store, after: pane?.stripModel.selectedID?.rawValue, window: window)
        if let pane {
            pane.apply(pane.snapshot())
            if focus { reveal(key, in: pane) }
        }
        return view(for: key)
    }

    /// `page` as `window`'s top page (one view per window, shown again on a
    /// repeat); nil when the run may not change the view.
    private func showTopPage(_ page: InternalPageID, in window: WindowController) -> InternalPageView? {
        let route = TopPageRoute.page(page)
        guard TopPages.show(route, services: window.services, in: window.state) != nil else { return nil }
        return window.topPages.views[route] as? InternalPageView
    }

    func reveal(_ key: String, in pane: PaneController) {
        pane.select(StripTabID(key))
        pane.focusContent()
    }

    /// The main window that shows a tab of `page` (debug and tests).
    func window(showing page: InternalPageID, windows: [WindowController]) -> WindowController? {
        windows.first { controller in
            guard let panes = controller.content?.panes.values else { return false }
            return tab(of: page, inPanes: panes.map(\.paneKey)) != nil
                || panes.contains { $0.pane.tabs.contains { $0.page == page.rawValue } }
        }
    }
}

extension AppServices {
    /// Whether `page` shows anywhere: a tab, or a window's top page (a
    /// focused show on Home opens it on top). A provider keeps a shared
    /// model while this is true.
    func pageIsOpen(_ page: InternalPageID) -> Bool {
        !pages.keys(of: page).isEmpty || windows.controllers.contains { $0.topPages.key(for: .page(page)) != nil }
    }

    /// The pane controller whose strip lists the page tab `key` (its
    /// provider key, or a store page tab's id).
    func paneController(showingTab key: String) -> PaneController? {
        for controller in windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] where pages.stripID(showing: key, in: pane) != nil || pane.tab(StripTabID(key))?.page != nil {
                return pane
            }
        }
        return nil
    }
}

// MARK: Discard (`memoryDiscardInternalPages`, p07-memory.md 3.C, task 022)
//
// Chrome discards a background tab and keeps the tab (strip place, title, favicon, navigation
// state), then reloads it when shown (chrome/browser/resource_coordinator/tab_lifecycle_unit.cc,
// `TabLifecycleUnit::Discard`). A page tab hidden past its provider's policy saves its view state
// and last picture, and its view and page renderer go; its next show makes the view again, under
// the picture until it paints, with the state put back. `discards` (a ContentDiscardScheduler)
// decides when; the content cache's lifecycle carries it: show and hide are a page tab's `reveal`
// and `conceal`, the discard is its `hibernate` event and `release` effect, a show of a discarded
// tab its `restore` effect, all under the lifecycle's tokens. The cache names a tab by its strip
// id: an app-only tab's key, or a store page tab's id, whose view lives under a provider key.
extension InternalPageTabStore {
    /// The page store whose discards follow `cache`'s lifecycle; nil while the feature is off.
    static func discarding(_ cache: TabContentCache) -> InternalPageTabStore? {
        guard let pages = cache.pageRequests.services?.pages, pages.discards != nil else { return nil }
        return pages
    }

    /// The provider key of `tab`: a store page tab's, else `tab` itself.
    func providerKey(ofTab tab: String) -> String { storeKey(of: tab) ?? tab }

    /// The registered provider of `tab`'s page; nil for a tab that is no page tab.
    func provider(ofTab tab: String) -> (any InternalPageProvider)? { page(ofTab: tab).flatMap { provider($0) } }

    /// Whether `tab`'s view was discarded and not made again yet.
    func isDiscarded(_ tab: String) -> Bool { discarded[providerKey(ofTab: tab)] != nil }

    /// The last picture of discarded page tab `tab`, from the content cache's previews.
    func discardedPicture(of tab: String) -> CGImage? { cache?.previews.image(for: tab) }

    // Lifecycle effects of page tabs; each is false for a tab that is no page tab.

    /// A `mount`: a page tab's view exists (the pane made it with its content), so it is live. Its
    /// memory is the discards' to manage, never the terminal warm set's.
    func adoptPage(_ tab: String) -> Bool {
        guard existingView(tab) != nil else { return false }
        cache?.ledger.setRetained(tab, false)
        return true
    }

    /// A `reveal`.
    func pageDidShow(_ tab: String) -> Bool {
        guard provider(ofTab: tab) != nil else { return false }
        discards?.contentDidShow(tab)
        return true
    }

    /// A `conceal`.
    func pageDidHide(_ tab: String) -> Bool {
        guard provider(ofTab: tab) != nil else { return false }
        discards?.contentDidHide(tab)
        return true
    }

    /// A `release`: the view goes with the state its preparation saved (none for a discard nobody
    /// prepared, the person's Hibernate Tab); a pane still holding it lets it go.
    func releasePage(_ tab: String, token: ContentLifecycle<String>.Token) -> Bool {
        guard provider(ofTab: tab) != nil else { return false }
        let state = discards?.takePrepared(tab) ?? ContentViewState()
        guard let cache, cache.lifecycle.accepts(tab, token) else { return true }
        cache.presenter(of: tab)?.surfaceWasDisplaced(tab)
        // A web page ends its bridge and engine session now, so its renderer goes with the view.
        let page = existingView(tab)?.content as? PageWebView
        guard discardView(ofTab: tab, state: state) else { return true }
        page?.close()
        cache.trace(tab, "page discarded \(token)")
        discards?.noteDiscarded(tab)
        return true
    }

    /// A `restore`: the pane made the view with its content, so it is live; with no view (a wake
    /// nobody shows) the tab stays discarded.
    func restorePage(_ tab: String, token: ContentLifecycle<String>.Token) -> Bool {
        guard provider(ofTab: tab) != nil else { return false }
        guard let cache else { return true }
        cache.applyLifecycle(cache.lifecycle.send(existingView(tab) != nil ? .mounted(tab, token) : .mountFailed(tab, token)))
        return true
    }
}

extension InternalPageTabStore: ContentDiscardHost {
    func discardPolicy(of key: String) -> ContentDiscardPolicy? {
        guard existingView(key) != nil, let provider = self.provider(ofTab: key) else { return nil }
        return provider.discardPolicy(for: providerKey(ofTab: key))
    }

    func keepReasons(of key: String) -> [CannotDiscardReason] {
        provider(ofTab: key)?.keepReasons(for: providerKey(ofTab: key)) ?? []
    }

    func isDrawn(_ key: String) -> Bool {
        existingView(key).map { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } ?? false
    }

    /// Saves hidden page tab `key`'s state and picture (none for a provider that keeps none, and
    /// any older one dropped). It stays (nil) when anything changed meanwhile: a show or hide (the
    /// lifecycle's generation), a new view, or a reason to keep it.
    func prepareDiscard(_ key: String) async -> ContentViewState? {
        guard let view = existingView(key), let provider = self.provider(ofTab: key), let record = cache?.lifecycle.record(key),
              record.phase == .mountedHidden else { return nil }
        let pageKey = providerKey(ofTab: key)
        let keepsPicture = provider.keepsDiscardPicture(for: pageKey)
        let state = await provider.saveViewState(for: pageKey, content: view.content)
        var picture: CGImage?
        if keepsPicture { picture = await view.lastPicture() }
        guard let cache, cache.lifecycle.record(key)?.generation == record.generation, existingView(key) === view,
              provider.keepReasons(for: pageKey).isEmpty else { return nil }
        if let picture {
            cache.previews.insert(picture, for: key)
        } else if !keepsPicture {
            cache.previews.remove(key)
        }
        return state
    }

    func commitDiscard(_ key: String) {
        guard let cache else { return }
        cache.applyLifecycle(cache.lifecycle.send(.hibernate(key)))
    }
}

