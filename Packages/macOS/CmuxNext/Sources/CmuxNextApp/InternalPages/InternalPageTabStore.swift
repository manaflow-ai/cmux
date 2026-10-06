import AppKit
import CmuxNextDaemon
import CmuxNextBridge
import CmuxNextTabs

/// Which internal page tabs each pane lists, and their views
/// (``InternalPage``). Like agent tabs they live only in this app session.
@MainActor
final class InternalPageTabStore {
    private var providers: [InternalPageID: any InternalPageProvider] = [:]
    private var tabsByPane: [String: [String]] = [:]
    private var views: [String: InternalPageView] = [:]
    /// The main window each tab opened in, for its provider's theme scope.
    private var windows: [String: WindowController] = [:]
    /// The daemon tree each pane with page tabs belongs to; watched so the
    /// tabs of a pane closed out of sight close once the tree drops it.
    private var paneStores: [String: DaemonStore] = [:]
    private var watches: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Sends `new-conversation-tab` for a page tab (`page-tabs-v1`) in a pane:
    /// the created tab and the event sequence its reply follows. Wired in
    /// `AppActions`; tests hold it.
    var createStoreTab: @MainActor (PaneID, DaemonService, String, ClientTransactionID) async throws
        -> (created: PageTabCreated, sequence: UInt64?) = { _, _, _, _ in throw DaemonError.notConnected }

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

    /// Every open tab of `page`.
    func keys(of page: InternalPageID) -> [String] {
        tabsByPane.values.flatMap { $0 }.filter { LocalPageTab.page(of: $0) == page }
    }

    func stripItem(_ key: String) -> StripTabItem {
        let provider = LocalPageTab.page(of: key).flatMap { providers[$0] }
        return StripTabItem(id: StripTabID(key), title: provider?.title(for: key) ?? "", subtitle: nil,
                            icon: .symbol(provider?.symbol ?? "square.dashed"), isBusy: false)
    }

    /// The tab's view, made on first show.
    func view(for key: String) -> InternalPageView? {
        if let view = views[key] { return view }
        guard tabsByPane.values.contains(where: { $0.contains(key) }), let page = LocalPageTab.page(of: key),
              let provider = providers[page] else { return nil }
        let view = InternalPageView(key: key, page: page, content: provider.makeView(for: key, in: windows[key]))
        views[key] = view
        return view
    }

    func existingView(_ key: String) -> InternalPageView? { views[key] }

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

    private static func livePanes(_ store: DaemonStore) -> Set<String>? {
        guard case .connected = store.connectionState, store.isLoaded else { return nil }
        return Set(store.workspaces.flatMap(\.screens).flatMap(\.panes).map(\.id))
    }

    private func watch(_ store: DaemonStore) {
        let id = ObjectIdentifier(store)
        guard watches[id] == nil else { return }
        // task-owner: stored in watches; cancelled once no pane of the store has page tabs
        watches[id] = Task { [weak self] in
            for await live in Observations({ Self.livePanes(store) }) where live != nil {
                guard let self else { return }
                self.closeGonePanes(in: store)
            }
        }
    }

    private func forgetUnusedStores() {
        paneStores = paneStores.filter { tabsByPane[$0.key] != nil }
        let used = Set(paneStores.values.map { ObjectIdentifier($0) })
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
