/// In-memory forgotten-Mac store for tests and previews.
public actor InMemoryPairedMacForgottenStore: PairedMacForgottenStoring {
    private var idsByScope: [String: Set<String>] = [:]

    /// Create an empty in-memory forgotten-Mac store.
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
