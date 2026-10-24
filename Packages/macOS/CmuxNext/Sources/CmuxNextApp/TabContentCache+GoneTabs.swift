import CmuxNextCompat
import CmuxNextDaemon

/// Releases the terminal surfaces and browser pages of tabs their daemon tree dropped (cx-x15rz). Closing a
/// workspace tears its panes down, which only hides their terminals: each closed tab kept its
/// surface in the warm set until the LRU took it, and its preview image in the preview cache.
/// A churn of workspace opens and closes grew the app by about 1.5 MB per cycle.
///
/// As ``AgentTabStore/releaseGoneTabs(in:)`` does for agent pages: a terminal goes once its
/// tree, connected and loaded, has listed its tab and no longer does. While a daemon is away
/// its terminals stay. Browser pages are tracked the same way: a tab the daemon closed
/// (`cmux tab close`, another client) kept its page, and a Chromium page its renderer.
@MainActor
final class GoneTabWatch {
    /// The tree each tracked tab is followed in. Only the narrow ``LiveTabListing`` seam: the
    /// watch can look up its own tabs and nothing else, so a tree change costs it its tracked tabs.
    private var stores: [String: any LiveTabListing] = [:]
    private var seenLive: Set<String> = []
    private var watches: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Follows tab `key` in `store`'s tree; `release` lets it go once the tree drops it.
    func track(_ key: String, in store: any LiveTabListing, release: @escaping @MainActor (String) -> Void) {
        if stores[key] === store { return }
        // Seen in another tree is not seen in this one: this tree must list it before it can drop it.
        if stores[key] != nil { seenLive.remove(key) }
        stores[key] = store
        if store.liveTreeLists(tab: key) == true { seenLive.insert(key) }
        let id = ObjectIdentifier(store)
        guard watches[id] == nil else { return }
        // task-owner: stored in watches; cancelled once no tracked terminal belongs to the store
        watches[id] = Task { [weak self] in
            for await revision in ObservationStream({ store.liveTabListRevision }) where revision != nil {
                guard let self else { return }
                for key in self.gone(in: store) { release(key) }
            }
        }
    }

    /// The tracked keys of `store` its live tree dropped; the ones it lists count as seen.
    private func gone(in store: any LiveTabListing) -> [String] {
        var gone: [String] = []
        for (key, owner) in stores where owner === store {
            guard let listed = store.liveTreeLists(tab: key) else { return [] }
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
        let used = Set(stores.values.map { ObjectIdentifier($0) })
        for id in watches.keys where !used.contains(id) {
            watches.removeValue(forKey: id)?.cancel()
        }
    }
}
