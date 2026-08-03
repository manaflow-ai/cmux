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

    /// The UserDefaults fallback value, type-erased for batch reset bookkeeping.
    public let userDefaultsDefaultValue: (any Sendable)?

    /// Default value in the Sendable editor representation.
    public let editorDefaultValue: SettingValue

    /// Reads this key through its typed store while preserving actor isolation.
    public let readEditorValue: @Sendable (
        UserDefaultsSettingsStore,
        JSONConfigStore,
        SecretFileStore
    ) async throws -> SettingValue

    /// Writes a validated editor value through this key's typed store.
    public let writeEditorValue: @Sendable (
        SettingValue,
        UserDefaultsSettingsStore,
        JSONConfigStore,
        SecretFileStore
    ) async throws -> Void

    /// Resets this key through its typed store.
    public let resetEditorValue: @Sendable (
        UserDefaultsSettingsStore,
        JSONConfigStore,
        SecretFileStore
    ) async throws -> Void

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
        self.userDefaultsDefaultValue = key.defaultValue
        self.editorDefaultValue = Self.editorValue(
            key.defaultValue.encodeForUserDefaults(),
            id: key.id
        )
        self.readEditorValue = { store, _, _ in
            let value = await store.value(for: key)
            return Self.editorValue(value.encodeForUserDefaults(), id: key.id)
        }
        self.writeEditorValue = { value, store, _, _ in
            guard let decoded = Value.decodeFromUserDefaults(value.encodedRepresentation) else {
                throw SettingValueError.unsupportedValue(key.id)
            }
            _ = await store.set(decoded, for: key)
        }
        self.resetEditorValue = { store, _, _ in
            _ = await store.reset(key)
        }
    }

    /// Wraps a JSON-backed key.
    public init<Value>(_ key: JSONKey<Value>) {
        self.id = key.id
        self.kind = .jsonConfig
        self.migrateUserDefaultsLegacyKeys = { _ in }
        self.resetInJSON = { store in
            try? await store.reset(key)
        }
        self.userDefaultsDefaultValue = nil
        self.editorDefaultValue = Self.editorValue(
            key.defaultValue.encodeForJSON(),
            id: key.id
        )
        self.readEditorValue = { _, store, _ in
            let value = await store.value(for: key)
            return Self.editorValue(value.encodeForJSON(), id: key.id)
        }
        self.writeEditorValue = { value, _, store, _ in
            guard let decoded = Value.decodeFromJSON(value.encodedRepresentation) else {
                throw SettingValueError.unsupportedValue(key.id)
            }
            try await store.set(decoded, for: key)
        }
        self.resetEditorValue = { _, store, _ in
            try await store.reset(key)
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
        self.userDefaultsDefaultValue = nil
        self.editorDefaultValue = .text(key.defaultValue)
        self.readEditorValue = { _, _, store in
            .text(try await store.value(for: key))
        }
        self.writeEditorValue = { value, _, _, store in
            guard case .text(let text) = value else {
                throw SettingValueError.unsupportedValue(key.id)
            }
            try await store.set(text, for: key)
        }
        self.resetEditorValue = { _, _, store in
            try await store.reset(key)
        }
    }

    private static func editorValue(_ raw: Any, id: String) -> SettingValue {
        SettingValue(encodedRepresentation: raw) ?? .text(String(describing: raw))
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
