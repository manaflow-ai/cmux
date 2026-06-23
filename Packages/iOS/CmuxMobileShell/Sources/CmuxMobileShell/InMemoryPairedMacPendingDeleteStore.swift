/// In-memory pending-delete store for tests and previews.
public actor InMemoryPairedMacPendingDeleteStore: PairedMacPendingDeleteStoring {
    private var idsByScope: [String: Set<String>] = [:]

    /// Create an empty in-memory pending-delete store.
    public init() {}

    /// Load pending tombstones for one account/team scope.
    public func load(scope: String) async -> Set<String> {
        idsByScope[scope] ?? []
    }

    /// Replace pending tombstones for one account/team scope.
    public func save(_ ids: Set<String>, scope: String) async {
        if ids.isEmpty {
            idsByScope.removeValue(forKey: scope)
        } else {
            idsByScope[scope] = ids
        }
    }

    /// Clear all pending tombstones.
    public func removeAll() async {
        idsByScope.removeAll()
    }
}
