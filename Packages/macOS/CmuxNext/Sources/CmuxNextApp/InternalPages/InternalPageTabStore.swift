import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextIcons
import CmuxNextTabs
import Observation

/// Which internal page tabs each pane lists, and their views
/// (``InternalPage``). Where the pane's daemon holds page tabs
/// (`page-tabs-v1`) a page opens as a store tab with a page source and
/// moves, splits and closes like any other tab; else it is an app-only tab
/// (`LocalPageTab`) this app session keeps. Observable for `tabsByPane`
/// only: the control snapshot lists app-only page tabs and republishes
/// when one opens or closes (bd cx-5xsi).
@Observable @MainActor
final class InternalPageTabStore {
    @ObservationIgnored private var providers: [InternalPageID: any InternalPageProvider] = [:]
    private var tabsByPane: [String: [String]] = [:]
    @ObservationIgnored private var views: [String: InternalPageView] = [:]
    /// The main window each tab opened in, for its provider's theme scope.
    @ObservationIgnored private var windows: [String: WindowController] = [:]
    /// The daemon tree each pane with page tabs belongs to; watched so the
    /// tabs of a pane closed out of sight close once the tree drops it.
    @ObservationIgnored private var paneStores: [String: DaemonStore] = [:]
    @ObservationIgnored private var watches: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Go Back (true) or Go Forward (false) from a page view's mouse buttons and swipes.
    @ObservationIgnored var navigate: ((Bool) -> Void)?
    /// Sends `new-conversation-tab` for a page tab (`page-tabs-v1`) in a pane:
    /// the created tab and the event sequence its reply follows. Sends it on
    /// the pane's daemon; tests hold it.
    @ObservationIgnored var createStoreTab: @MainActor (PaneID, DaemonService, String, ClientTransactionID) async throws
        -> (created: PageTabCreated, sequence: UInt64?) = { pane, daemon, page, transaction in
        guard let connection = daemon.connection else { throw DaemonError.notConnected }
        let request = NewConversationTabRequest(page: page, pane: pane, origin: InternalPageTabStore.createOrigin,
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
        tabsByPane[paneKey] = tabs
        windows[key] = window
        paneStores[paneKey] = store
        watch(store)
        return key
    }

    func tabIDs(in paneKey: String) -> [String] { tabsByPane[paneKey] ?? [] }

    /// The first tab of `page` among `paneKeys`, with its pane.
    func tab(of page: InternalPageID, inPanes paneKeys: some Sequence<String>) -> (pane: String, key: String)? {
        for pane in paneKeys {
            if let key = tabsByPane[pane]?.first(where: { LocalPageTab.page(of: $0) == page }) { return (pane, key) }
        }
        return nil
    }

    /// Every open tab of `page`, by the key its provider knows it by.
    func keys(of page: InternalPageID) -> [String] {
        (tabsByPane.values.flatMap { $0 } + Set(storeKeys.values).sorted()).filter { LocalPageTab.page(of: $0) == page }
    }

    /// The strip id of `pane`'s tab whose provider key is `key`: the key
    /// itself for an app-only tab, else the store tab's id.
    func stripID(showing key: String, in pane: PaneController) -> StripTabID? {
        if tabIDs(in: pane.paneKey).contains(key) { return StripTabID(key) }
        return pane.pane.tabs.first { storeKeys[$0.id] == key }.map { StripTabID($0.id) }
    }

    func stripItem(_ key: String) -> StripTabItem {
        let provider = LocalPageTab.page(of: key).flatMap { providers[$0] }
        return StripTabItem(id: StripTabID(key), title: provider?.title(for: key) ?? "", subtitle: nil,
                            icon: Self.tabIcon(provider), isBusy: false)
    }

    /// A page tab's strip icon: the page's cmux icon, else its SF Symbol.
    static func tabIcon(_ provider: (any InternalPageProvider)?) -> TabIcon {
        guard let provider else { return .icon(.placeholder) }
        return provider.icon.map(TabIcon.icon) ?? .symbol(provider.symbol)
    }

    /// The tab's view, made on first show.
    func view(for key: String) -> InternalPageView? {
        if let view = views[key] { return view }
        guard tabsByPane.values.contains(where: { $0.contains(key) }), let page = LocalPageTab.page(of: key),
              let provider = providers[page] else { return nil }
        let view = InternalPageView(key: key, page: page, content: provider.makeView(for: key, in: windows[key]))
        view.navigate = navigate
        views[key] = view
        return view
    }

    /// `key`'s view: an app-only page tab's, or a store page tab's by its id.
    func existingView(_ key: String) -> InternalPageView? { views[key] ?? storeKeys[key].flatMap { views[$0] } }

    /// The page an app-only or store page tab shows.
    func page(ofTab tab: String) -> InternalPageID? {
        LocalPageTab.page(of: tab) ?? storeKeys[tab].flatMap(LocalPageTab.page(of:))
    }

    // MARK: Store page tabs

    /// A store page tab's strip title and icon, from the page it shows.
    func storeTabItem(_ tab: TabModel) -> (title: String, icon: TabIcon)? {
        guard let page = tab.page.map(InternalPageID.init(rawValue:)), let provider = providers[page] else { return nil }
        return (provider.title(for: storeKeys[tab.id] ?? ""), Self.tabIcon(provider))
    }

    /// The view of store page tab `tab` (its `page` source), made on first
    /// show under a provider key of its own.
    func view(forStoreTab tab: TabModel, in store: DaemonStore, window: WindowController?) -> InternalPageView? {
        if let key = storeKeys[tab.id], let view = views[key] { return view }
        guard let page = tab.page.map(InternalPageID.init(rawValue:)), let provider = providers[page] else { return nil }
        let key = storeKeys[tab.id] ?? LocalPageTab.makeKey(page)
        track(tab.id, key: key, in: store, window: window)
        // A pane lists it: the tree has it.
        seenLive.insert(tab.id)
        let view = InternalPageView(key: key, page: page, content: provider.makeView(for: key, in: windows[key]))
        view.navigate = navigate
        views[key] = view
        return view
    }

    /// Opens `page` as a store tab after `pane`'s selected tab. The tab and
    /// its view show at once (the store's provisional tab) and keep the
    /// view when the store's tab replaces it. Selects it when `focus`. Nil
    /// when the pane's daemon cannot hold page tabs. A failed creation keeps
    /// the page as an app-only tab.
    func openStoreTab(_ page: InternalPageID, in pane: PaneController, window: WindowController,
                      focus: Bool) -> InternalPageView? {
        let daemon = pane.daemon, store = daemon.store
        guard let provider = providers[page], daemon.supports(DaemonCapabilities.shared.pageTabs),
              case .connected = store.connectionState else { return nil }
        let provisional = ProvisionalTab()
        let key = LocalPageTab.makeKey(page)
        var snapshot = TabSnapshot(surface: provisional.surface, tabResourceID: ResourceID(rawValue: provisional.id),
                                   kind: .conversation, title: provider.title(for: key), browserRenderer: "frontend")
        snapshot.conversation = ConversationTabRef(page: page.rawValue)
        track(provisional.id, key: key, in: store, window: window)
        let view = InternalPageView(key: key, page: page, content: provider.makeView(for: key, in: window))
        views[key] = view
        store.onPageTabCreated = { [weak self] provisional, tab in
            self?.storeTabCreated(provisional, as: tab.id, surface: tab.surface)
        }
        let transaction = ClientTransactionID.generate()
        store.intend(.createTab(pane: pane.pane.handle, provisional: snapshot), transaction: transaction)
        if focus {
            pane.selectWhenReported(surface: provisional.surface)
            pane.focusContent()
        } else {
            pane.apply(pane.snapshot())
        }
        let create = createStoreTab, handle = pane.pane.handle
        pane.services.registry.track(Task { @MainActor [weak self, weak pane] () -> ActionWorkFailure? in
            do {
                let (created, sequence) = try await create(handle, daemon, page.rawValue, transaction)
                self?.storeTabCreated(provisional.id, as: created.key, surface: created.surface)
                // The store's tab replaces the provisional one in one step, never beside it.
                ProvisionalTab.created(transaction, surface: created.surface, in: store)
                if let sequence { store.noteSettled(transaction, at: sequence) } else { store.noteSettledAtNextSnapshot(transaction) }
            } catch {
                daemon.logger.error("new-conversation-tab (page) failed: \(String(describing: error), privacy: .public)")
                self?.keepAsLocalTab(provisional.id, key: key, page: page, in: pane, store: store, window: window)
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
    private func keepAsLocalTab(_ id: String, key: String, page: InternalPageID, in pane: PaneController?,
                                store: DaemonStore, window: WindowController) {
        storeKeys[id] = nil
        storeTabStores[id] = nil
        seenLive.remove(id)
        guard let pane else {
            if !storeKeys.values.contains(key) { forget(key) }
            return
        }
        let selected = pane.stripModel.selectedID?.rawValue == id
        open(page, in: pane.paneKey, of: store, after: id, window: window, key: key)
        pane.apply(pane.snapshot())
        if selected { reveal(key, in: pane) }
    }

    /// Lets the view of every store page tab `store` listed and lists no
    /// longer go (closed here or on another client).
    func closeGoneStoreTabs(in store: DaemonStore) {
        guard let live = Self.liveTabs(store) else { return }
        for (id, owner) in storeTabStores where owner === store {
            if live.contains(id) {
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
        for pane in tabsByPane.keys { tabsByPane[pane]?.removeAll { $0 == key } }
        tabsByPane = tabsByPane.filter { !$0.value.isEmpty }
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
        guard let live = Self.livePanes(store) else { return }
        for (paneKey, owner) in paneStores where owner === store && !live.contains(paneKey) {
            closePane(paneKey)
        }
    }

    private func forget(_ key: String) {
        views.removeValue(forKey: key)?.removeFromSuperview()
        windows[key] = nil
        if let page = LocalPageTab.page(of: key) { providers[page]?.tabClosed(key) }
    }

    private static func liveTabs(_ store: DaemonStore) -> Set<String>? {
        guard case .connected = store.connectionState, store.isLoaded else { return nil }
        return Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.id))
    }

    private static func livePanes(_ store: DaemonStore) -> Set<String>? {
        guard case .connected = store.connectionState, store.isLoaded else { return nil }
        return Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).map(\.id))
    }

    private func watch(_ store: DaemonStore) {
        let id = ObjectIdentifier(store)
        guard watches[id] == nil else { return }
        // task-owner: stored in watches; cancelled once the store has no page tabs
        watches[id] = Task { [weak self] in
            for await live in Observations({ Self.livePanes(store).map { [$0, Self.liveTabs(store) ?? []] } }) where live != nil {
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
