import AppKit
import CmuxNextHibernation
import CmuxNextPages

// MARK: Discard (`memoryDiscardInternalPages`, p07-memory.md 3.C, task 022)
//
// Chrome discards a background tab and keeps the tab (strip place, title, favicon, navigation
// state), then reloads it when shown (chrome/browser/resource_coordinator/tab_lifecycle_unit.cc,
// `TabLifecycleUnit::Discard`). A page tab hidden past its provider's policy saves its view state
// and route, and its provider tears its view down; its next show makes the view again, under the
// picture taken when it hid, with the route and state put back. `discards` (a
// ContentDiscardScheduler) decides when; the content cache's lifecycle carries it, through its
// ``PageTabLifecycleHandling`` seam: show and hide are a page tab's `reveal` and `conceal`, the
// discard is its `hibernate` event and `release` effect, a show of a discarded tab its `restore`
// effect, all under the lifecycle's tokens. The cache names a tab by its strip id: an app-only
// tab's key, or a store page tab's id, whose view lives under a provider key.

/// Page tab discards while `memoryDiscardInternalPages` is on: when views go (`scheduler`), on whose
/// lifecycle (`cache`), and what each tab keeps meanwhile, by provider key.
@MainActor
final class InternalPageDiscards {
    /// What a discarded page tab keeps until its view is made again.
    struct Record {
        /// What its view showed besides its route.
        var state: ContentViewState
        /// ``InternalPageProvider/route(for:)`` at the discard, given back before the next view.
        var route: String?
    }

    /// The picture of a page tab taken at a hide: the capture on its way, then what it shows.
    struct Picture {
        var task: Task<Void, Never>?
        /// ``InternalPageTabStore/pictureVersion(_:)`` of the page the stored picture shows.
        var version: Int?
    }

    let scheduler: ContentDiscardScheduler
    weak var cache: TabContentCache?
    var discarded: [String: Record] = [:]
    var pictures: [String: Picture] = [:]

    init(scheduler: ContentDiscardScheduler, cache: TabContentCache) {
        self.scheduler = scheduler
        self.cache = cache
    }

    /// Tab `key` closed: nothing of it stays.
    func forget(_ key: String) {
        discarded[key] = nil
        pictures.removeValue(forKey: key)?.task?.cancel()
    }
}

/// The content lifecycle's effects on page tabs, which ``TabContentCache`` hands to its
/// `pageDiscards` (set only while `memoryDiscardInternalPages` is on). Each returns false for a
/// tab that is no page tab, which then takes the cache's own path.
@MainActor
protocol PageTabLifecycleHandling: AnyObject {
    /// A `mount`: whether `tab` is a page tab whose view exists, so it is live.
    func adoptPage(_ tab: String) -> Bool
    /// A `reveal`.
    func pageDidShow(_ tab: String) -> Bool
    /// A `conceal` under `token`.
    func pageDidHide(_ tab: String, token: ContentLifecycle<String>.Token) -> Bool
    /// A `release` under `token`: the view goes.
    func releasePage(_ tab: String, token: ContentLifecycle<String>.Token) -> Bool
    /// A `restore` under `token`: the view is back.
    func restorePage(_ tab: String, token: ContentLifecycle<String>.Token) -> Bool
}

extension InternalPageTabStore {
    /// Turns page tab discards on: `scheduler` says when views go, on `cache`'s lifecycle.
    func enableDiscards(_ scheduler: ContentDiscardScheduler, on cache: TabContentCache) {
        discarding = InternalPageDiscards(scheduler: scheduler, cache: cache)
        scheduler.host = self
        cache.pageDiscards = self
    }

    var discards: ContentDiscardScheduler? { discarding?.scheduler }
    var cache: TabContentCache? { discarding?.cache }

    /// The provider key of `tab`: a store page tab's, else `tab` itself.
    func providerKey(ofTab tab: String) -> String { storeKey(of: tab) ?? tab }

    /// The registered provider of `tab`'s page; nil for a tab that is no page tab.
    func provider(ofTab tab: String) -> (any InternalPageProvider)? { page(ofTab: tab).flatMap { self.provider($0) } }

    /// Whether `tab`'s view was discarded and not made again yet.
    func isDiscarded(_ tab: String) -> Bool { discarding?.discarded[providerKey(ofTab: tab)] != nil }

    /// Lets `tab`'s view go and keeps the tab (strip place, title, icon), its route and `state`,
    /// given back to the view made at its next show. The provider tears the view down
    /// (``InternalPageProvider/viewDiscarded(_:)``). False with no view.
    @discardableResult
    func discardView(ofTab tab: String, state: ContentViewState) -> Bool {
        let key = providerKey(ofTab: tab)
        guard let discarding, let view = takeView(key) else { return false }
        view.removeFromSuperview()
        let owner = LocalPageTab.page(of: key).flatMap { self.provider($0) }
        discarding.discarded[key] = InternalPageDiscards.Record(state: state, route: owner?.route(for: key))
        owner?.viewDiscarded(key)
        return true
    }

    /// The last picture of page tab `tab`, from the content cache's previews.
    func discardedPicture(of tab: String) -> CGImage? { cache?.previews.image(for: tab) }

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
        guard let discarding, let cache = discarding.cache, provider.discardPolicy(for: key) != .never,
              let view = existingView(tab), let page = view.content as? PageWebView, page.hasPainted else { return }
        let version = Self.pictureVersion(page)
        if discarding.pictures[key]?.version == version, cache.previews.image(for: tab) != nil { return }
        discarding.pictures[key]?.task?.cancel()
        // task-owner: discarding.pictures[key]; cancelled by the next hide's capture or the tab's close
        let task = Task { [weak self, weak view, weak cache] in
            guard let image = await view?.lastPicture(), !Task.isCancelled, let self, let cache,
                  cache.lifecycle.accepts(tab, token), self.existingView(tab) === view else { return }
            cache.previews.insert(image, for: tab)
            self.discarding?.pictures[key]?.version = version
        }
        discarding.pictures[key] = InternalPageDiscards.Picture(task: task, version: discarding.pictures[key]?.version)
    }
}

extension InternalPageTabStore: PageTabLifecycleHandling {
    /// A page tab's memory is the discards' to manage, never the terminal warm set's.
    func adoptPage(_ tab: String) -> Bool {
        guard existingView(tab) != nil else { return false }
        cache?.ledger.setRetained(tab, false)
        return true
    }

    func pageDidShow(_ tab: String) -> Bool {
        guard provider(ofTab: tab) != nil else { return false }
        discards?.contentDidShow(tab)
        return true
    }

    func pageDidHide(_ tab: String, token: ContentLifecycle<String>.Token) -> Bool {
        guard let provider = self.provider(ofTab: tab) else { return false }
        discards?.contentDidHide(tab)
        takePicture(of: tab, provider: provider, token: token)
        return true
    }

    /// The view goes with the state its preparation saved (none for a discard nobody prepared, the
    /// person's Hibernate Tab); a pane still holding it lets it go. The provider tears it down.
    func releasePage(_ tab: String, token: ContentLifecycle<String>.Token) -> Bool {
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

    /// Saves hidden page tab `key`'s state, once the picture its hide took has landed. It stays (nil)
    /// when anything changed meanwhile: a show or hide (the lifecycle's generation), a new view, or a
    /// reason to keep it.
    func prepareDiscard(_ key: String) async -> ContentViewState? {
        guard let view = existingView(key), let provider = self.provider(ofTab: key), let cache,
              let record = cache.lifecycle.record(key), record.phase == .mountedHidden else { return nil }
        let pageKey = providerKey(ofTab: key)
        await discarding?.pictures[pageKey]?.task?.value
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
