import CmuxNextDaemon

/// The daemon tree each held tab or pane id belongs to, indexed both ways: by id, and the ids
/// each tree holds. An owner of per-tab or per-pane state (``GoneTabWatch``, ``AgentTabStore``,
/// ``InternalPageTabStore``) wakes on one tree's tab list change and asks only about the ids it
/// holds in that tree (``keys(in:)``), not every id it holds in every tree.
@MainActor
struct StoreKeys {
    private var stores: [String: DaemonStore] = [:]
    private var held: [ObjectIdentifier: Set<String>] = [:]

    /// The tree `key` belongs to; setting nil forgets it.
    subscript(key: String) -> DaemonStore? {
        get { stores[key] }
        set {
            if let old = stores[key] {
                let id = ObjectIdentifier(old)
                held[id]?.remove(key)
                if held[id]?.isEmpty == true { held[id] = nil }
            }
            stores[key] = newValue
            if let newValue { held[ObjectIdentifier(newValue), default: []].insert(key) }
        }
    }

    /// Forgets `key`; returns the tree it belonged to.
    @discardableResult
    mutating func removeValue(forKey key: String) -> DaemonStore? {
        let old = stores[key]
        self[key] = nil
        return old
    }

    /// The ids held in `store`'s tree.
    func keys(in store: DaemonStore) -> Set<String> { held[ObjectIdentifier(store)] ?? [] }

    /// The trees any id is held in.
    var storeIDs: Set<ObjectIdentifier> { Set(held.keys) }

    /// Forgets every id `isKept` refuses.
    mutating func keep(where isKept: (String) -> Bool) {
        for key in stores.keys where !isKept(key) { self[key] = nil }
    }
}
