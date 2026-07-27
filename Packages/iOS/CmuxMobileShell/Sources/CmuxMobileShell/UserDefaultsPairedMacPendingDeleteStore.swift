public import Foundation

/// UserDefaults-backed pending-delete store for production. The values are only
/// Mac device IDs keyed by Stack account/team scope; no routes or hostnames are
/// stored in this outbox.
public actor UserDefaultsPairedMacPendingDeleteStore: PairedMacPendingDeleteStoring {
    private let defaults: UserDefaults
    private let key: String

    /// Create a durable pending-delete store.
    public init(
        defaults: UserDefaults = .standard,
        key: String = "cmux.mobile.pairedMacBackup.pendingDeletes.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Create a durable pending-delete store in a named UserDefaults suite.
    public init(
        suiteName: String,
        key: String = "cmux.mobile.pairedMacBackup.pendingDeletes.v1"
    ) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = key
    }

    /// Load pending tombstones for one account/team scope.
    public func load(scope: String) async -> Set<String> {
        let all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set(all[scope] ?? [])
    }

    /// Replace pending tombstones for one account/team scope.
    public func save(_ ids: Set<String>, scope: String) async {
        var all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        if ids.isEmpty {
            all.removeValue(forKey: scope)
        } else {
            all[scope] = ids.sorted()
        }
        defaults.set(all, forKey: key)
    }

    /// Clear all pending tombstones.
    public func removeAll() async {
        defaults.removeObject(forKey: key)
    }
}
