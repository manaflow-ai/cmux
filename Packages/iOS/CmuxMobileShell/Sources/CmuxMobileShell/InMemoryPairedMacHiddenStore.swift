/// In-memory hidden-Mac store for tests and previews.
public actor InMemoryPairedMacHiddenStore: PairedMacHiddenStoring {
    private var idsByScope: [String: Set<String>] = [:]

    /// Create an empty in-memory hidden-Mac store.
    public init() {}

    /// Load hidden Mac pairing ids for one account/team scope.
    public func load(scope: String) async -> Set<String> {
        idsByScope[scope] ?? []
    }

    /// Replace hidden Mac pairing ids for one account/team scope.
    public func save(_ ids: Set<String>, scope: String) async {
        if ids.isEmpty {
            idsByScope.removeValue(forKey: scope)
        } else {
            idsByScope[scope] = ids
        }
    }

    /// Clear every remembered hidden id.
    public func removeAll() async {
        idsByScope.removeAll()
    }
}
