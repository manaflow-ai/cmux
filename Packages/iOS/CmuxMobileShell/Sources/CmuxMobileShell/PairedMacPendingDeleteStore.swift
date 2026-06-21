public import Foundation

/// Local outbox for paired-Mac backup tombstones that have not yet been
/// confirmed by a successful upload.
public protocol PairedMacPendingDeleteStoring: Sendable {
    /// Load pending tombstones for one account/team scope.
    func load(scope: String) async -> Set<String>

    /// Replace pending tombstones for one account/team scope.
    func save(_ ids: Set<String>, scope: String) async

    /// Clear all pending tombstones.
    func removeAll() async
}

/// In-memory pending-delete store for tests and previews.
public actor InMemoryPairedMacPendingDeleteStore: PairedMacPendingDeleteStoring {
    private var idsByScope: [String: Set<String>] = [:]

    /// Create an empty in-memory pending-delete store.
    public init() {}

    public func load(scope: String) async -> Set<String> {
        idsByScope[scope] ?? []
    }

    public func save(_ ids: Set<String>, scope: String) async {
        if ids.isEmpty {
            idsByScope.removeValue(forKey: scope)
        } else {
            idsByScope[scope] = ids
        }
    }

    public func removeAll() async {
        idsByScope.removeAll()
    }
}

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

    public func load(scope: String) async -> Set<String> {
        return Set(Self.loadAll(defaults: defaults, key: key)[scope] ?? [])
    }

    public func save(_ ids: Set<String>, scope: String) async {
        var all = Self.loadAll(defaults: defaults, key: key)
        if ids.isEmpty {
            all.removeValue(forKey: scope)
        } else {
            all[scope] = ids.sorted()
        }
        defaults.set(all, forKey: key)
    }

    public func removeAll() async {
        defaults.removeObject(forKey: key)
    }

    private static func loadAll(defaults: UserDefaults, key: String) -> [String: [String]] {
        defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }
}
