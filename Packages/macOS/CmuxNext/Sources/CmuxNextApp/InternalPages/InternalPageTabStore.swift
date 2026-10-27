import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextIcons
import CmuxNextSettingsWindow
import CmuxNextTabs
import Observation

/// Internal page tabs and their views; provider registration is observed.
@Observable @MainActor
final class InternalPageTabStore {
    private var providers: [InternalPageID: any InternalPageProvider] = [:]
    private let tabsByPane = ObservedMap<String, [String]>()
    @ObservationIgnored private var views: [String: InternalPageView] = [:]
    /// The main window each tab opened in, for its provider's theme scope.
    @ObservationIgnored private var windows: [String: WindowController] = [:]
    /// The daemon tree each pane with page tabs belongs to; watched so the
    /// tabs of a pane closed out of sight close once the tree drops it.
    @ObservationIgnored private var paneStores: [String: DaemonStore] = [:]
    @ObservationIgnored private var watches: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Go Back (true) or Go Forward (false) from a page view's mouse buttons and swipes.
    @ObservationIgnored var navigate: ((Bool) -> Void)?
    /// Sends `new-conversation-tab` for a page tab (`page-tabs-v1`) on its
    /// route (`page-tab-route-v1`) in a pane: the created tab and the event
    /// sequence its reply follows. Sends it on the pane's daemon; tests hold it.
    @ObservationIgnored var createStoreTab: @MainActor (PaneID, DaemonService, String, String?, ClientTransactionID) async throws
        -> (created: PageTabCreated, sequence: UInt64?) = { pane, daemon, page, route, transaction in
        guard let connection = daemon.connection else { throw DaemonError.notConnected }
        let request = NewConversationTabRequest(page: page, route: route, pane: pane, origin: InternalPageTabStore.createOrigin,
                                                mutationID: UUID().uuidString.lowercased(), transaction: transaction)
        let response = try await connection.request(request)
        let created = PageTabCreated(key: response.tabResourceID?.rawValue ?? "surface:\(response.surface.rawValue)",
                                     surface: response.surface)
        // Every event the daemon sent before the reply: the provisional tab settles there.
        return (created, await connection.eventSequence())
    }
    /// Store page tabs: each store (or provisional) tab id and the provider
    /// key its view and state live under.
    @ObservationIgnored private var storeKeys: [String: String] = [:]
    /// The daemon tree each store page tab belongs to.
    @ObservationIgnored private var storeTabStores: [String: DaemonStore] = [:]
    /// Store page tabs a live tree has listed; gone from it, they closed.
    @ObservationIgnored private var seenLive: Set<String> = []

    static func isPreviewPage(_ page: String?) -> Bool {
        page == InternalPageID.appStore.rawValue || page == InternalPageID.changelog.rawValue
    }

    /// Whether `daemon` keeps a page tab's route (`page-tab-route-v1`).
    func keepsRoutes(_ daemon: DaemonService) -> Bool {
        daemon.supports(DaemonCapability.pageTabRoute.rawValue)
    }

    /// The `origin` of the app's `new-conversation-tab` requests for page tabs.
    static let createOrigin = "cmux-next-page-tab"

    /// Registers the owner of `provider.page`. A second provider of the
    /// same page replaces the first.
    func register(_ provider: any InternalPageProvider) {
        providers[provider.page] = provider
    }

    func provider(_ page: InternalPageID) -> (any InternalPageProvider)? { providers[page] }

    /// Adds a tab of `page` to `paneKey`'s strip after `after` (else at the
    /// end) and returns its id: `key` when the provider made it first (so it
    /// can hold the tab's state before the view exists), else a new one.
    @discardableResult
    func open(_ page: InternalPageID, in paneKey: String, of store: DaemonStore, after: String? = nil,
              window: WindowController? = nil, key: String? = nil) -> String {
        let key = key.flatMap { LocalPageTab.page(of: $0) == page ? $0 : nil } ?? LocalPageTab.makeKey(page)
        var tabs = tabsByPane[paneKey] ?? []
        if let after, let index = tabs.firstIndex(of: after) {
            tabs.insert(key, at: index + 1)
        } else {
            tabs.append(key)
        }
        tabsByPane[paneKey] = tabs.isEmpty ? nil : tabs
        windows[key] = window
        paneStores[paneKey] = store
        watch(store)
        return key
    }

    func tabIDs(in paneKey: String) -> [String] { tabsByPane[paneKey] ?? [] }

    /// The panes that have page tabs (observes the pane set).
    var paneKeys: [String] { tabsByPane.keys }

    /// The first tab of `page` among `paneKeys`, with its pane.
    func tab(of page: InternalPageID, inPanes paneKeys: some Sequence<String>) -> (pane: String, key: String)? {
        for pane in paneKeys {
            if let key = tabsByPane[pane]?.first(where: { LocalPageTab.page(of: $0) == page }) { return (pane, key) }
        }
        return nil
    }

    /// Every open tab of `page`, by the key its provider knows it by.
    func keys(of page: InternalPageID) -> [String] {
        (tabsByPane.entries.flatMap(\.value) + Set(storeKeys.values).sorted()).filter { LocalPageTab.page(of: $0) == page }
    }

    /// The strip id of `pane`'s tab whose provider key is `key`: the key
    /// itself for an app-only tab, else the store tab's id.
    func stripID(showing key: String, in pane: PaneController) -> StripTabID? {
        if tabIDs(in: pane.paneKey).contains(key) { return StripTabID(key) }
        return pane.pane.tabs.first { storeKeys[$0.id] == key }.map { StripTabID($0.id) }
    }

    func stripItem(_ key: String) -> StripTabItem {
        let page = LocalPageTab.page(of: key), provider = page.flatMap { providers[$0] }
        return StripTabItem(id: StripTabID(key), title: Self.tabTitle(provider, key: key, page: page), subtitle: nil,
                            icon: Self.tabIcon(provider), isBusy: false)
    }

    /// Fallback title while a restored provider is still registering.
    private static func tabTitle(_ provider: (any InternalPageProvider)?, key: String, page: InternalPageID?) -> String {
        if let title = provider?.title(for: key), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        if let title = provider?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        guard let page, !page.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return Strings.untitledBrowser }
        return switch page { case .settings: SettingsDeepLink.pageTitle; case .debugSettings: DebugSettingsModel.paneTitle; case .changelog: ChangelogPageStrings.title; default: page.rawValue }
    }

    static func tabIcon(_ provider: (any InternalPageProvider)?) -> TabIcon {
        guard let provider else { return .icon(.fileText) }
        return provider.icon.map(TabIcon.icon) ?? .symbol(provider.symbol)
    }

    /// The tab's view, made on first show.
    func view(for key: String) -> InternalPageView? {
        if let page = LocalPageTab.page(of: key), page == .appStore || page == .changelog,
           windows[key]?.services.settings?.snapshot.previewFeatures != true { return nil }
        if let view = views[key] { return view }
        guard tabsByPane.entries.contains(where: { $0.value.contains(key) }), let page = LocalPageTab.page(of: key),
              let provider = providers[page] else { return nil }
        let content = provider.makeView(for: key, in: windows[key])
        let view = InternalPageView(key: key, page: page, content: content, topBar: provider.makeTopBar(for: key))
        view.navigate = navigate
        views[key] = view
        return view
    }

    /// `key`'s view: an app-only page tab's, or a store page tab's by its id.
    /// The provider key of store page tab `id`, nil for any other tab.
    func storeKey(of id: String) -> String? { storeKeys[id] }

    func existingView(_ key: String) -> InternalPageView? { views[key] ?? storeKeys[key].flatMap { views[$0] } }

    /// The page an app-only or store page tab shows.
    func page(ofTab tab: String) -> InternalPageID? {
        LocalPageTab.page(of: tab) ?? storeKeys[tab].flatMap(LocalPageTab.page(of:))
    }

    // MARK: Store page tabs

    /// A store page tab's strip title and icon, from the page it shows.
    func storeTabItem(_ tab: TabModel, page: InternalPageID? = nil) -> (title: String, icon: TabIcon)? {
        guard let page = page ?? tab.page.map(InternalPageID.init(rawValue:)) else { return nil }
        let provider = providers[page]
        // A restored tab before its first show has no key yet: its route names what it shows.
        if storeKeys[tab.id] == nil, let route = tab.pageRoute, let title = provider?.title(forRoute: route) {
            return (title, Self.tabIcon(provider))
        }
        return (Self.tabTitle(provider, key: storeKeys[tab.id] ?? "", page: page), Self.tabIcon(provider))
    }

    /// The view of store page tab `tab` (its `page` source, or `page` for an
    /// app tab, `app-screens-v1`), made on first show under a provider key of
    /// its own. A tab this app did not open shows its route
    /// (`page-tab-route-v1`) only from this Mac's daemon (`local`): another
    /// machine's daemon never names a file or folder for this Mac to read.
    func view(forStoreTab tab: TabModel, page: InternalPageID? = nil, in store: DaemonStore, local: Bool = false,
              window: WindowController?) -> InternalPageView? {
        guard let page = page ?? tab.page.map(InternalPageID.init(rawValue:)) else { return nil }
        if page == .appStore || page == .changelog,
           window?.services.settings?.snapshot.previewFeatures != true { return nil }
        if let key = storeKeys[tab.id], let view = views[key] {
            // The tab moved to another window: the same view shows there, and its window follows.
            if let window { windows[key] = window }
            return view
        }
        guard let provider = providers[page] else { return nil }
        guard let key = prepareStoreTab(tab, page: page, in: store, local: local, window: window) else { return nil }
        let content = provider.makeView(for: key, in: windows[key])
        let view = InternalPageView(key: key, page: page, content: content, topBar: provider.makeTopBar(for: key))
        view.navigate = navigate
        views[key] = view
        return view
    }

    /// Resolves a restored tab's provider key and route without creating its view.
    func prepareStoreTab(_ tab: TabModel, page: InternalPageID, in store: DaemonStore, local: Bool,
                         window: WindowController?) -> String? {
        guard let provider = providers[page] else { return nil }
        let key = storeKeys[tab.id] ?? LocalPageTab.makeKey(page)
        // A tab this app did not open (Reopen Closed, relaunch, another app): its route says what it shows.
        if local, storeKeys[tab.id] == nil, let route = tab.pageRoute { provider.restore(route, for: key) }
        track(tab.id, key: key, in: store, window: window)
        // A pane lists it: the tree has it.
        seenLive.insert(tab.id)
        return key
    }

    /// Opens `page` as a store tab after `pane`'s selected tab. The tab and
    /// its view show at once (the store's provisional tab) and keep the
    /// view when the store's tab replaces it. Selects it when `focus`. Nil
    /// when the pane's daemon cannot hold page tabs. A failed creation keeps
    /// the page as an app-only tab. `key` is the provider key to use (a
    /// provider that set up its tab under it first); `created` gets the
    /// store tab's surface once the daemon made it.
    func openStoreTab(_ page: InternalPageID, in pane: PaneController, window: WindowController,
                      focus: Bool, key given: String? = nil,
                      created onCreated: (@MainActor (SurfaceID) -> Void)? = nil) -> InternalPageView? {
        openStoreTab(page, in: pane.pane, of: pane.daemon, services: pane.services, controller: pane, window: window,
                     focus: focus, key: given, created: onCreated)
    }

    /// ``openStoreTab(_:in:window:focus:key:created:)`` in model pane `model` of `daemon`. With no
    /// `controller` (a workspace parked off screen, whose new panes have none until it shows) the
    /// tab goes into the model only, and its pane shows it when the workspace shows; `focus` then
    /// selects nothing (a focused show leaves the top page first, which shows the workspace).
    func openStoreTab(_ page: InternalPageID, in model: PaneModel, of daemon: DaemonService, services: AppServices,
                      controller pane: PaneController?, window: WindowController, focus: Bool, key given: String? = nil,
                      created onCreated: (@MainActor (SurfaceID) -> Void)? = nil) -> InternalPageView? {
        let store = daemon.store
        // Nothing opens in Home's dock (an app page, a file): without a placement of the caller's, the tab moves beside it.
        let onCreated = onCreated ?? HomeDockOpens.placing(model, services: services, focus: focus, then: nil)
        guard let provider = providers[page], daemon.supports(DaemonCapability.pageTabs.rawValue),
              case .connected = store.connectionState else { return nil }
        let provisional = ProvisionalTab()
        let key = given.flatMap { LocalPageTab.page(of: $0) == page ? $0 : nil } ?? LocalPageTab.makeKey(page)
        var snapshot = TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id),
                                   kind: .conversation, title: provider.title(for: key), browserRenderer: "frontend")
        // The route goes only to a daemon that keeps it; an older one would drop it.
        let route = daemon.supports(DaemonCapability.pageTabRoute.rawValue) ? provider.route(for: key) : nil
        snapshot.conversation = ConversationTabRef(page: page.rawValue, route: route)
        track(provisional.id, key: key, in: store, window: window)
        let view = InternalPageView(key: key, page: page, content: provider.makeView(for: key, in: window), topBar: provider.makeTopBar(for: key))
        views[key] = view
        store.onPageTabCreated = { [weak self] provisional, tab in
            self?.storeTabCreated(provisional, as: tab.id, surface: tab.surface)
        }
        let transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: model.handle, provisional: snapshot), transaction: transaction)
        if let pane {
            if focus {
                pane.selectWhenReported(surface: provisional.surface)
                pane.focusContent()
            } else {
                pane.apply(pane.snapshot())
            }
        }
        let create = createStoreTab, handle = model.handle, paneKey = model.id
        services.registry.track(Task { @MainActor [weak self, weak pane] () -> ActionWorkFailure? in
            do {
                let (created, sequence) = try await create(handle, daemon, page.rawValue, route, transaction)
                // Closed first (CancelledCreation): nothing moves to the store's tab, nothing is reported.
                if !store.creations.wasCancelled(transaction) { self?.storeTabCreated(provisional.id, as: created.key, surface: created.surface) }
                // The store's tab replaces the provisional one in one step, never beside it.
                ProvisionalTab.created(transaction, surface: created.surface, in: store)
                if let sequence { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
                if !store.creations.wasCancelled(transaction) { onCreated?(created.surface) }
            } catch {
                daemon.logger.error("new-conversation-tab (page) failed: \(String(describing: error), privacy: .public)")
                if !store.creations.wasCancelled(transaction) {
                    self?.keepAsLocalTab(provisional.id, key: key, page: page, in: paneKey, controller: pane, store: store, window: window)
                }
                store.rejectIntent(transaction)
            }
            return nil
        })
        return view
    }

    /// The store created provisional page tab `provisional` as `real` on
    /// `surface` (its reply or its echo, whichever came first): the view
    /// and the selection move to it.
    func storeTabCreated(_ provisional: String, as real: String, surface: SurfaceID) {
        guard provisional != real, let key = storeKeys[provisional] else { return }
        storeKeys[real] = key
        storeTabStores[real] = storeTabStores[provisional]
        // The provisional id resolves until the tree drops it.
        seenLive.insert(provisional)
        for pane in windows[key]?.content?.panes.values.map({ $0 }) ?? []
        where pane.stripModel.selectedID?.rawValue == provisional {
            pane.selectWhenReported(surface: surface)
        }
    }

    /// The store refused provisional page tab `id`: its page stays, as an
    /// app-only tab in `pane` holding the same view, selected if it was.
    private func keepAsLocalTab(_ id: String, key: String, page: InternalPageID, in paneKey: String, controller pane: PaneController?,
                                store: DaemonStore, window: WindowController) {
        storeKeys[id] = nil
        storeTabStores[id] = nil
        seenLive.remove(id)
        // The pane went meanwhile: nothing holds the page.
        guard store.liveTreeLists(pane: paneKey) != false else {
            if !storeKeys.values.contains(key) { forget(key) }
            return
        }
        let selected = pane?.stripModel.selectedID?.rawValue == id
        open(page, in: paneKey, of: store, after: id, window: window, key: key)
        guard let pane else { return }
        pane.apply(pane.snapshot())
        if selected { reveal(key, in: pane) }
    }

    /// Lets the view of every store page tab `store` listed and lists no
    /// longer go (closed here or on another client).
    func closeGoneStoreTabs(in store: DaemonStore) {
        guard store.liveTabListRevision != nil else { return }
        for (id, owner) in storeTabStores where owner === store {
            if store.liveTreeLists(tab: id) == true {
                seenLive.insert(id)
            } else if seenLive.contains(id) {
                seenLive.remove(id)
                storeTabStores[id] = nil
                if let key = storeKeys.removeValue(forKey: id), !storeKeys.values.contains(key) { forget(key) }
            }
        }
        forgetUnusedStores()
    }

    private func track(_ id: String, key: String, in store: DaemonStore, window: WindowController?) {
        storeKeys[id] = key
        storeTabStores[id] = store
        if let window { windows[key] = window }
        watch(store)
    }

    /// The tab closed: drop its view and tell its provider.
    func close(_ key: String) {
        for (pane, tabs) in tabsByPane.entries where tabs.contains(key) {
            let rest = tabs.filter { $0 != key }
            tabsByPane[pane] = rest.isEmpty ? nil : rest
        }
        forget(key)
        forgetUnusedStores()
    }

    /// The pane closed: close every page tab it listed.
    func closePane(_ paneKey: String) {
        for key in tabsByPane.removeValue(forKey: paneKey) ?? [] { forget(key) }
        forgetUnusedStores()
    }

    /// Closes the page tabs of every pane `store` no longer lists, once it
    /// is connected with a live tree.
    func closeGonePanes(in store: DaemonStore) {
        // The panes this store tracks, each by lookup: never the session's pane set.
        let gone = paneStores.filter { $0.value === store && store.liveTreeLists(pane: $0.key) == false }.map(\.key)
        for paneKey in gone { closePane(paneKey) }
    }

    private func forget(_ key: String) {
        views.removeValue(forKey: key)?.removeFromSuperview()
        windows[key] = nil
        if let page = LocalPageTab.page(of: key) { providers[page]?.tabClosed(key) }
    }

    private func watch(_ store: DaemonStore) {
        let id = ObjectIdentifier(store)
        guard watches[id] == nil else { return }
        // task-owner: stored in watches; cancelled once the store has no page tabs
        watches[id] = Task { [weak self] in
            // One observed value: the tab-list revision changes when a tab or a pane comes, goes or moves.
            for await live in ObservationStream({ store.liveTabListRevision }) where live != nil {
                guard let self else { return }
                self.closeGonePanes(in: store)
                self.closeGoneStoreTabs(in: store)
            }
        }
    }

    private func forgetUnusedStores() {
        paneStores = paneStores.filter { tabsByPane[$0.key] != nil }
        let used = Set((Array(paneStores.values) + Array(storeTabStores.values)).map { ObjectIdentifier($0) })
        for id in watches.keys where !used.contains(id) {
            watches.removeValue(forKey: id)?.cancel()
        }
    }
}

/// The store tab a page tab's `new-conversation-tab` created.
struct PageTabCreated: Sendable, Equatable {
    var key: String
    var surface: SurfaceID
}
