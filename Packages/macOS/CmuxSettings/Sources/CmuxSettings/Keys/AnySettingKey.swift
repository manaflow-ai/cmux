import Foundation

/// Type-erased view onto a ``DefaultsKey``, ``JSONKey``, or ``SecretFileKey``.
///
/// Used to enumerate every catalog entry uniformly — for example when running
/// legacy-key migrations at app startup, building schema docs, or driving the
/// settings search index. The concrete key types are generic over `Value` and
/// can't live in a single heterogeneous array, so ``AnySettingKey`` strips
/// the value type while preserving the metadata needed for those tasks.
///
/// Type-sensitive operations (like legacy-key migration, which must validate
/// that the legacy value decodes as the new key's `Value` before copying)
/// are exposed as closures that capture `Value` at construction.
public struct AnySettingKey: Sendable {
    /// Which storage backend the underlying key targets, plus its
    /// backend-specific metadata.
    public enum Kind: Sendable, Hashable {
        /// The key persists in `UserDefaults`.
        ///
        /// - Parameters:
        ///   - key: The UserDefaults storage key.
        ///   - suite: Optional suite name (`nil` for `UserDefaults.standard`).
        ///   - legacyKeys: Renamed keys to migrate from on first read.
        case userDefaults(key: String, suite: String?, legacyKeys: [String])

        /// The key persists in the cmux JSON config file at the key's ``id``.
        case jsonConfig

        /// The key persists in its own private `0600` file managed by
        /// ``SecretFileStore``, never in the shared `cmux.json`.
        ///
        /// - Parameter fileName: The secret's file name under the secret
        ///   store's base directory.
        case secretFile(fileName: String)
    }

    /// The dotted identifier from the underlying key.
    public let id: String

    /// Where the underlying key persists, plus backend-specific metadata.
    public let kind: Kind

    /// Runs legacy-key migration for this entry against a `UserDefaults`
    /// suite. The closure was captured with the underlying `Value` type, so
    /// it validates the legacy value decodes correctly before copying — a
    /// type mismatch (e.g. legacy was Bool, new is String) is detected and
    /// the migration is skipped rather than silently coercing.
    ///
    /// No-op for ``Kind/jsonConfig`` keys.
    public let migrateUserDefaultsLegacyKeys: @Sendable (UserDefaults) -> Void

    /// Removes this key from the JSON config store, if it is a
    /// JSON-backed key. No-op for ``Kind/userDefaults`` keys. Errors
    /// from the underlying ``JSONConfigStore/reset(_:)`` call are
    /// swallowed because batch reset paths (e.g. ``ResetSection``)
    /// surface them separately or treat them as best-effort.
    public let resetInJSON: @Sendable (JSONConfigStore) async -> Void

    /// Wraps a UserDefaults-backed key.
    public init<Value>(_ key: DefaultsKey<Value>) {
        self.id = key.id
        self.kind = .userDefaults(
            key: key.userDefaultsKey,
            suite: key.suite,
            legacyKeys: key.legacyUserDefaultsKeys
        )
        self.migrateUserDefaultsLegacyKeys = { defaults in
            AnySettingKey.migrateLegacyDefaultsKey(key, defaults: defaults)
        }
        self.resetInJSON = { _ in }
    }

    /// Wraps a JSON-backed key.
    public init<Value>(_ key: JSONKey<Value>) {
        self.id = key.id
        self.kind = .jsonConfig
        self.migrateUserDefaultsLegacyKeys = { _ in }
        self.resetInJSON = { store in
            try? await store.reset(key)
        }
    }

    /// Wraps a secret-file-backed key. Secrets are reset through
    /// ``SecretFileStore`` rather than ``JSONConfigStore``, so ``resetInJSON``
    /// is a no-op here.
    public init(_ key: SecretFileKey) {
        self.id = key.id
        self.kind = .secretFile(fileName: key.fileName)
        self.migrateUserDefaultsLegacyKeys = { _ in }
        self.resetInJSON = { _ in }
    }

    private static func migrateLegacyDefaultsKey<Value>(
        _ key: DefaultsKey<Value>,
        defaults: UserDefaults
    ) {
        guard !key.legacyUserDefaultsKeys.isEmpty else { return }
        guard defaults.object(forKey: key.userDefaultsKey) == nil else { return }
        for legacy in key.legacyUserDefaultsKeys {
            guard let raw = defaults.object(forKey: legacy) else { continue }
            // Only migrate if the legacy value decodes as the new key's
            // Value type. Otherwise the legacy entry was a different shape
            // and copying would silently produce stale defaults; leave the
            // primary key empty and let the default value take effect.
            guard Value.decodeFromUserDefaults(raw) != nil else { continue }
            defaults.set(raw, forKey: key.userDefaultsKey)
            for cleanup in key.legacyUserDefaultsKeys {
                defaults.removeObject(forKey: cleanup)
            }
            return
        }
    }
}

extension AnySettingKey: Equatable {
    public static func == (lhs: AnySettingKey, rhs: AnySettingKey) -> Bool {
        lhs.id == rhs.id && lhs.kind == rhs.kind
    }
}

extension AnySettingKey: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(kind)
    }
}

/// Internal protocol that both ``DefaultsKey`` and ``JSONKey`` conform to so
/// ``SettingCatalog`` can derive ``SettingCatalogSection/all`` via reflection.
protocol AnySettingKeyConvertible {
    var asAnySettingKey: AnySettingKey { get }
}

extension DefaultsKey: AnySettingKeyConvertible {
    var asAnySettingKey: AnySettingKey { AnySettingKey(self) }
}

extension JSONKey: AnySettingKeyConvertible {
    var asAnySettingKey: AnySettingKey { AnySettingKey(self) }
}

extension SecretFileKey: AnySettingKeyConvertible {
    var asAnySettingKey: AnySettingKey { AnySettingKey(self) }
}
