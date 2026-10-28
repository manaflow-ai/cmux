import CmuxNextDaemon
import CmuxNextWakeups

/// Releases the terminal surfaces and browser pages of tabs their daemon tree dropped (cx-x15rz). Closing a
/// workspace tears its panes down, which only hides their terminals: each closed tab kept its
/// surface in the warm set until the LRU took it, and its preview image in the preview cache.
/// A churn of workspace opens and closes grew the app by about 1.5 MB per cycle.
///
/// As ``AgentTabStore/releaseGoneTabs(in:)`` does for agent pages: a terminal goes once its
/// tree, connected and loaded, has listed its tab and no longer does. While a daemon is away
/// its terminals stay. Browser pages are tracked the same way: a tab the daemon closed
/// (`cmux tab close`, another client) kept its page, and a Chromium page its renderer.
///
/// One ServiceObservation per store, whose apply only posts the walk as one
/// background task per store: freeing memory is work nobody sees, so a burst of tab-list changes is
/// one walk of the tracked tabs, after the person's and the visible work, whether or not any of those
/// tabs shows. The observation applies a person's tab close in their input-response pass; only the
/// post runs there, so no cause moves the walk or a release onto the key-to-frame path.
@MainActor
final class GoneTabWatch {
    private let mainWork: MainWorkScheduler
    private var stores: [String: DaemonStore] = [:]
    private var seenLive: Set<String> = []
    private var watches: [ObjectIdentifier: ServiceObservation<UInt64?>] = [:]
    /// Stores whose walk is posted and has not run: a burst of changes posts one.
    private var walksPosted: Set<ObjectIdentifier> = []
    /// Tab records this watch examined since it was made, over every tree change it woke for: what a
    /// tree change costs it. Tests read it; it must follow the tabs it tracks, not the session.
    private(set) var tabsVisited = 0

    /// `mainWork`: the app's one main-thread scheduler, which runs each store's walk.
    init(mainWork: MainWorkScheduler) {
        self.mainWork = mainWork
    }

    /// Follows tab `key` in `store`'s tree; `release` lets it go once the tree drops it.
    func track(_ key: String, in store: DaemonStore, release: @escaping @MainActor (String) -> Void) {
        if stores[key] === store { return }
        // Seen in another tree is not seen in this one: this tree must list it before it can drop it.
        if stores[key] != nil { seenLive.remove(key) }
        stores[key] = store
        if store.liveTreeLists(tab: key) == true { seenLive.insert(key) }
        let id = ObjectIdentifier(store)
        guard watches[id] == nil else { return }
        // Stored in watches; cancelled once no tracked terminal belongs to the store. The revision now is the
        // tree this call just read: no walk for it.
        let start = store.liveTabListRevision
        watches[id] = ServiceObservation(.background, owner: "GoneTabWatch", on: mainWork) { [weak store] in
            store?.liveTabListRevision
        } apply: { [weak self, weak store] revision in
            guard revision != nil, revision != start, let self, let store else { return }
            postWalk(of: store, release: release)
        }
    }

    /// Posts one walk of `store`'s tracked tabs as background work, unless one is posted already.
    private func postWalk(of store: DaemonStore, release: @escaping @MainActor (String) -> Void) {
        let id = ObjectIdentifier(store)
        guard walksPosted.insert(id).inserted else { return }
        // node-free: memory nobody sees is freed whether or not any tracked tab shows.
        mainWork.post(.background, owner: "GoneTabWatch") { [weak self, weak store] in
            guard let self else { return }
            walksPosted.remove(id)
            guard let store, watches[id] != nil else { return }
            for key in gone(in: store) { release(key) }
        }
    }

    /// The tracked keys of `store` its live tree dropped; the ones it lists count as seen.
    private func gone(in store: DaemonStore) -> [String] {
        var gone: [String] = []
        for (key, owner) in stores where owner === store {
            guard let listed = store.liveTreeLists(tab: key) else { return [] }
            tabsVisited += 1
            if listed {
                seenLive.insert(key)
            } else if seenLive.contains(key) {
                gone.append(key)
            }
        }
        return gone
    }

    /// True while `key` is followed: from its first page or surface until it is released.
    func tracks(_ key: String) -> Bool { stores[key] != nil }

    /// `key` was released (by its tab closing or by its tree dropping it).
    func forget(_ key: String) {
        stores[key] = nil
        seenLive.remove(key)
        let used = Set(stores.values.map(ObjectIdentifier.init))
        for id in watches.keys where !used.contains(id) {
            watches.removeValue(forKey: id)?.cancel()
        }
    }
}
