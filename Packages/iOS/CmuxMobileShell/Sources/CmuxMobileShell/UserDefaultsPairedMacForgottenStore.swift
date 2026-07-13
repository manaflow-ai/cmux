public import Foundation

/// UserDefaults-backed forgotten-Mac store for production.
public actor UserDefaultsPairedMacForgottenStore: PairedMacForgottenStoring {
    private let defaults: UserDefaults
    private let key: String

    /// Create a durable forgotten-Mac store.
    public init(
        defaults: UserDefaults = .standard,
        key: String = "cmux.mobile.pairedMacs.forgotten.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Create a durable forgotten-Mac store in a named UserDefaults suite.
    public init(
        suiteName: String,
        key: String = "cmux.mobile.pairedMacs.forgotten.v1"
    ) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = key
    }

    /// Load forgotten Mac device ids for one account/team scope.
    public func load(scope: String) async -> Set<String> {
        let all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return Set(all[scope] ?? [])
    }

    /// Replace forgotten Mac device ids for one account/team scope.
    public func save(_ ids: Set<String>, scope: String) async {
        var all = defaults.dictionary(forKey: key) as? [String: [String]] ?? [:]
        if ids.isEmpty {
            all.removeValue(forKey: scope)
        } else {
            all[scope] = ids.sorted()
        }
        defaults.set(all, forKey: key)
    }

    /// Clear every remembered forgotten id.
    public func removeAll() async {
        defaults.removeObject(forKey: key)
    }
}
