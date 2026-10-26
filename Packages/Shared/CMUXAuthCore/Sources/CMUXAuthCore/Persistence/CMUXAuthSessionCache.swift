import Foundation

/// Persists the "this device has stored auth tokens" flag across launches.
///
/// Read at launch priming so the app can show a restoring state instead of
/// flashing signed-out while the real session validates over the network.
/// Backed by an injected ``CMUXAuthKeyValueStore`` under a caller-chosen key,
/// so each app keeps its historical defaults key and tests use an in-memory
/// store.
///
/// Not `Sendable`: the cache belongs to the one isolation domain that owns it
/// (the main-actor `AuthCoordinator`), like ``CMUXAuthIdentityStore``.
public final class CMUXAuthSessionCache {
    private let keyValueStore: CMUXAuthKeyValueStore
    private let key: String

    /// Creates a session cache.
    /// - Parameters:
    ///   - keyValueStore: The injected key-value backing store.
    ///   - key: The key the flag persists under.
    public init(keyValueStore: CMUXAuthKeyValueStore, key: String) {
        self.keyValueStore = keyValueStore
        self.key = key
    }

    /// Whether tokens were stored when the flag was last written.
    public var hasTokens: Bool {
        keyValueStore.bool(forKey: key)
    }

    /// Record whether tokens are currently stored.
    public func setHasTokens(_ value: Bool) {
        keyValueStore.set(value, forKey: key)
    }

    /// Remove the flag entirely.
    public func clear() {
        keyValueStore.removeObject(forKey: key)
    }
}
