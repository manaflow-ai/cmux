public import Foundation

/// Loads and saves usage history.
public protocol FrecencyPersisting: AnyObject {
    func load() -> FrecencyStore?
    func save(_ store: FrecencyStore)
}

/// Keeps history in `UserDefaults` under one JSON key.
public final class UserDefaultsFrecencyPersistence: FrecencyPersisting {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "cmuxNext.palette.frecency.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> FrecencyStore? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(FrecencyStore.self, from: data)
    }

    public func save(_ store: FrecencyStore) {
        guard let data = try? JSONEncoder().encode(store) else { return }
        defaults.set(data, forKey: key)
    }
}

/// History that lives only in memory (tests, demos).
public final class InMemoryFrecencyPersistence: FrecencyPersisting {
    public private(set) var stored: FrecencyStore?

    public init(_ store: FrecencyStore? = nil) {
        stored = store
    }

    public func load() -> FrecencyStore? { stored }
    public func save(_ store: FrecencyStore) { stored = store }
}
