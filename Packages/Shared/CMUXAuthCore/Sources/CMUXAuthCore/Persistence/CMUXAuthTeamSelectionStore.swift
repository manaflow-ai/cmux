import Foundation

/// Persists the user's selected team id across launches.
///
/// Backed by an injected ``CMUXAuthKeyValueStore`` (production: `UserDefaults`)
/// under a caller-chosen key, so each app keeps its historical defaults key and
/// tests can use an in-memory store. Empty and whitespace-only values normalize
/// to `nil` so a cleared selection round-trips as "no selection".
///
/// `@unchecked Sendable`: the only state is the injected key-value store and an
/// immutable key; the production backing (`UserDefaults`) is Apple-documented
/// thread-safe, matching ``CMUXAuthSessionCache`` and ``CMUXAuthIdentityStore``.
public final class CMUXAuthTeamSelectionStore: @unchecked Sendable {
    private let keyValueStore: CMUXAuthKeyValueStore
    private let key: String

    /// Creates a team selection store.
    /// - Parameters:
    ///   - keyValueStore: The injected key-value backing store.
    ///   - key: The key the selected team id persists under.
    public init(keyValueStore: CMUXAuthKeyValueStore, key: String) {
        self.keyValueStore = keyValueStore
        self.key = key
    }

    /// The persisted selected team id, or `nil` when none is stored.
    public var selectedTeamID: String? {
        get { Self.normalized(keyValueStore.string(forKey: key)) }
        set {
            if let normalized = Self.normalized(newValue) {
                keyValueStore.set(normalized, forKey: key)
            } else {
                keyValueStore.removeObject(forKey: key)
            }
        }
    }

    /// Remove any persisted selection.
    public func clear() {
        keyValueStore.removeObject(forKey: key)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
