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
            return tabView(forStoreTab: tab, in: daemon.store, local: daemon.isLocal, window: window)
        }
        if let found = tab(of: page, inPanes: panes.map(\.id)) {
            if focus, let controller = panes.first(where: { $0.id == found.pane }).flatMap(content.controller(for:)) {
                reveal(found.key, in: controller)
            }
            return tabView(for: found.key)
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
        return tabView(for: key)
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
// and route, and its provider tears its view down; its next show makes the view again, under the
// picture taken when it hid, with the route and state put back. `discards` (a
// ContentDiscardScheduler) decides when, `discardRecords` keeps what each discarded tab needs; the
// content cache's lifecycle carries it, through its `contentOwners`: show and hide are a
// page tab's `reveal` and `conceal`, the discard is its `hibernate` event and `release` effect, a
// show of a discarded tab its `restore` effect, all under the lifecycle's tokens. The cache names a tab by its strip id: an app-only
// tab's key, or a store page tab's id, whose view lives under a provider key.

extension InternalPageTabStore {
    /// Turns page tab discards on: `scheduler` says when views go, on `cache`'s lifecycle.
    func enableDiscards(_ scheduler: ContentDiscardScheduler, on cache: TabContentCache) {
        discards = scheduler
        self.cache = cache
        scheduler.host = self
        cache.contentOwners.add(self)
    }

    /// The provider key of `tab`: a store page tab's, else `tab` itself.
    func providerKey(ofTab tab: String) -> String { storeKey(of: tab) ?? tab }

    /// The registered provider of `tab`'s page; nil for a tab that is no page tab.
    func provider(ofTab tab: String) -> (any InternalPageProvider)? { page(ofTab: tab).flatMap { self.provider($0) } }

    /// Whether `tab`'s view was discarded and not made again yet.
    func isDiscarded(_ tab: String) -> Bool { discardRecords.discarded[providerKey(ofTab: tab)] != nil }

    /// Lets `tab`'s view go and keeps the tab (strip place, title, icon), its route and `state`,
    /// given back to the view made at its next show. The provider tears the view down
    /// (``InternalPageProvider/viewDiscarded(_:)``). False with no view, or one whose content never showed.
    @discardableResult
    func discardView(ofTab tab: String, state: ContentViewState) -> Bool {
        let key = providerKey(ofTab: tab)
        guard discards != nil, existingView(key) != nil, let view = takeView(key) else { return false }
        view.removeFromSuperview()
        view.detachContent() // while the view lives (InternalPageView.detachContent)
        let owner = LocalPageTab.page(of: key).flatMap { self.provider($0) }
        discardRecords.discarded[key] = ContentDiscardRecords.Record(state: state, route: owner?.route(for: key))
        owner?.viewDiscarded(key)
        return true
    }

    /// The last picture of page tab `tab`, from the content cache's internal page pictures.
    func discardedPicture(of tab: String) -> CGImage? { cache?.internalPagePictures.image(for: tab) }

    /// What `page`'s picture shows, as far as the app can tell: its document (the view and its first
    /// paint), its route, and the person's last input in it (a scroll, a click, a key).
    static func pictureVersion(_ page: PageWebView) -> Int {
        var hasher = Hasher()
        hasher.combine(ObjectIdentifier(page))
        hasher.combine(page.paintedUptime)
        hasher.combine(page.route)
        hasher.combine(page.lastUserEventUptime)
        return hasher.finalize()
    }

    /// The hide is the last chance to picture `tab`'s page (the engine cannot picture a hidden page,
    /// TabContentCache+Lifecycle `conceal`): a page that may be discarded and painted is pictured
    /// unless its picture shows what it shows now. The picture is kept only while this hide is the
    /// tab's latest transition and the tab still has this view.
    private func takePicture(of tab: String, provider: any InternalPageProvider, token: ContentLifecycle<String>.Token) {
        let key = providerKey(ofTab: tab)
        guard discards != nil, let cache, provider.discardPolicy(for: key) != .never, provider.keepsDiscardPicture(for: key),
              let view = existingView(tab), let page = view.content as? PageWebView, page.hasPainted else { return }
        let version = Self.pictureVersion(page)
        let records = discardRecords
        if records.pictures[key]?.version == version, cache.internalPagePictures.image(for: tab) != nil { return }
        records.pictures[key]?.task?.cancel()
        // task-owner: discardRecords.pictures[key]; cancelled by the next hide's capture or the tab's close
        let task = Task { [weak self, weak view, weak cache, weak records] in
            guard let image = await view?.lastPicture() else { return }
            let picture = await cache?.internalPagePictures.picture(of: image)
            guard !Task.isCancelled, let self, let cache, cache.lifecycle.accepts(tab, token), self.existingView(tab) === view else { return }
            // A picture the store refused (nil) keeps no version: the next hide pictures the page again.
            records?.pictures[key]?.version = cache.internalPagePictures.insert(picture, for: tab) ? version : nil
        }
        records.pictures[key] = ContentDiscardRecords.Picture(task: task, version: records.pictures[key]?.version)
    }
}

// The content lifecycle's effects on page tabs, which the cache hands to its `contentOwners`. Each
// returns false for a tab that is no page tab, which then takes the cache's own path.
extension InternalPageTabStore: ContentLifecycleOwner {
    /// A page tab's memory is the discards' to manage, never the terminal warm set's.
    func contentAdopted(_ tab: String) -> Bool {
        guard existingView(tab) != nil else { return false }
        cache?.ledger.setRetained(tab, false)
        return true
    }

    func contentDidShow(_ tab: String) -> Bool {
        guard provider(ofTab: tab) != nil else { return false }
        discards?.contentDidShow(tab)
        return true
    }

    func contentDidHide(_ tab: String, token: ContentLifecycle<String>.Token) -> Bool {
        guard let provider = self.provider(ofTab: tab) else { return false }
        discards?.contentDidHide(tab)
        takePicture(of: tab, provider: provider, token: token)
        return true
    }

    /// The view goes with the state its preparation saved (none for a discard nobody prepared, the
    /// person's Hibernate Tab); a pane still holding it lets it go. The provider tears it down.
    func releaseContent(_ tab: String, token: ContentLifecycle<String>.Token) -> Bool {
        guard provider(ofTab: tab) != nil else { return false }
        let state = discards?.takePrepared(tab) ?? ContentViewState()
        guard let cache, cache.lifecycle.accepts(tab, token) else { return true }
        cache.presenter(of: tab)?.surfaceWasDisplaced(tab)
        guard discardView(ofTab: tab, state: state) else { return true }
        cache.trace(tab, "page discarded \(token)")
        discards?.noteDiscarded(tab)
        return true
    }

    /// The pane made the view with its content, so it is live; with no view (a wake nobody shows)
    /// the tab stays discarded.
    func restoreContent(_ tab: String, token: ContentLifecycle<String>.Token) -> Bool {
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
        // visibility-walk-allow: a paint hold keeps a hidden tab's view drawn; its tab node says hidden, only the view knows
        existingView(key).map { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor } ?? false
    }

    /// Saves hidden page tab `key`'s state, once the picture its hide took has landed (a provider
    /// that keeps no picture has none, and any older one is dropped). It stays (nil) when anything
    /// changed meanwhile: a show or hide (the lifecycle's generation), a new view, or a reason to keep it.
    func prepareDiscard(_ key: String) async -> ContentViewState? {
        guard let view = existingView(key), let provider = self.provider(ofTab: key), let cache,
              let record = cache.lifecycle.record(key), record.phase == .mountedHidden else { return nil }
        let pageKey = providerKey(ofTab: key)
        if provider.keepsDiscardPicture(for: pageKey) {
            await discardRecords.pictures[pageKey]?.task?.value
        } else {
            cache.internalPagePictures.remove(key)
        }
        let state = await provider.saveViewState(for: pageKey, content: view.content)
        guard cache.lifecycle.record(key)?.generation == record.generation, existingView(key) === view,
              provider.keepReasons(for: pageKey).isEmpty else { return nil }
        return state
    }

    func commitDiscard(_ key: String) {
        guard let cache else { return }
        cache.applyLifecycle(cache.lifecycle.send(.hibernate(key)))
    }
}
