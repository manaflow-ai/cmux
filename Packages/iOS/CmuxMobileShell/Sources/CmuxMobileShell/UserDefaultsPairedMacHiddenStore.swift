public import Foundation

/// UserDefaults-backed hidden-Mac store for production.
public actor UserDefaultsPairedMacHiddenStore: PairedMacHiddenStoring {
    private let defaults: UserDefaults
    private let key: String

    /// Create a durable hidden-Mac store.
    public init(
        defaults: UserDefaults = .standard,
        // Deliberately retained so Macs deleted by older clients migrate into Hidden Computers.
        key: String = "cmux.mobile.pairedMacs.forgotten.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Create a durable hidden-Mac store in a named UserDefaults suite.
    public init(
        suiteName: String,
        // Deliberately retained so Macs deleted by older clients migrate into Hidden Computers.
        key: String = "cmux.mobile.pairedMacs.forgotten.v1"
    ) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = key
    }

    /// Load hidden Mac pairing ids for one account/team scope.
    public func load(scope: String) async -> Set<String> {
        let all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set(all[scope] ?? [])
    }

    /// Replace hidden Mac pairing ids for one account/team scope.
    public func save(_ ids: Set<String>, scope: String) async {
        var all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        if ids.isEmpty {
            all.removeValue(forKey: scope)
        } else {
            all[scope] = ids.sorted()
        }
        defaults.set(all, forKey: key)
    }

    /// Clear every remembered hidden id.
    public func removeAll() async {
        defaults.removeObject(forKey: key)
    }
}
