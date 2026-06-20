public import Foundation

/// `UserDefaults`-backed store for the primary window's last frame and display.
///
/// Faithful lift of the window-geometry persistence half of the `AppDelegate`
/// session block (`persistedWindowGeometry`, `persistWindowGeometry`,
/// `encodedPersistedWindowGeometryData`, `decodedPersistedWindowGeometryData`,
/// and `removeLegacyPersistedWindowGeometry`). The behavior is unchanged:
/// every read and write first removes the legacy v1 keys, the payload is
/// JSON-encoded/decoded through the app's `Codable` value, and a decoded
/// payload whose `version` differs from ``schemaVersion`` is discarded (and,
/// on read, the corrupt entry is removed). The defaults key, legacy keys, and
/// schema version are injected so the FROZEN wire format
/// (`cmux.session.lastWindowGeometry.v2`) lives at the composition root.
///
/// Isolation: a stateless `Sendable` struct, not an actor. Every method is
/// synchronous because its callers are: the legacy reads/writes ran inline on
/// the main actor (geometry is read during startup and written from a window
/// observer), and the autosave path that writes raw geometry data already hops
/// to its own serial queue app-side. There is no mutable state to protect.
public struct WindowGeometryStore<Payload: WindowGeometryPersisting>: Sendable {
    /// The current geometry schema version. A persisted payload with any other
    /// version is unusable. Legacy `persistedWindowGeometrySchemaVersion` (2).
    public let schemaVersion: Int

    /// The `UserDefaults` key the current-version payload is stored under.
    /// Legacy `persistedWindowGeometryDefaultsKey`
    /// (`cmux.session.lastWindowGeometry.v2`).
    public let defaultsKey: String

    /// Older `UserDefaults` keys removed on every read and write so a stale
    /// pre-v2 entry never lingers. Legacy
    /// `legacyPersistedWindowGeometryDefaultsKeys`.
    public let legacyDefaultsKeys: [String]

    /// Creates a store.
    ///
    /// - Parameters:
    ///   - schemaVersion: the current geometry schema version; persisted
    ///     payloads with any other version are discarded.
    ///   - defaultsKey: the `UserDefaults` key for the current-version payload.
    ///   - legacyDefaultsKeys: older keys removed on every read and write.
    public init(
        schemaVersion: Int,
        defaultsKey: String,
        legacyDefaultsKeys: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.defaultsKey = defaultsKey
        self.legacyDefaultsKeys = legacyDefaultsKeys
    }

    /// Loads the persisted geometry payload, or nil when absent or unusable.
    ///
    /// Removes the legacy keys first, then reads and decodes the current key.
    /// A corrupt or wrong-version entry is removed and nil is returned, exactly
    /// as the legacy `persistedWindowGeometry(defaults:)` did.
    public func load(defaults: UserDefaults) -> Payload? {
        removeLegacy(defaults: defaults)
        guard let data = defaults.data(forKey: defaultsKey) else {
            return nil
        }
        guard let payload = decode(data) else {
            defaults.removeObject(forKey: defaultsKey)
            return nil
        }
        return payload
    }

    /// Persists `payload` under the current key, removing the legacy keys
    /// first. Legacy `persistWindowGeometry(frame:display:defaults:)` plus its
    /// `encodedPersistedWindowGeometryData` encode. A payload that fails to
    /// encode is silently dropped, matching the legacy guard.
    public func save(_ payload: Payload, defaults: UserDefaults) {
        removeLegacy(defaults: defaults)
        guard let data = encode(payload) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    /// Writes already-encoded geometry `data` under the current key, removing
    /// the legacy keys first. Used by the snapshot-save path, which encodes the
    /// payload itself so it can share one write block with the snapshot file.
    /// Legacy autosave `writeBlock` geometry branch.
    public func saveEncoded(_ data: Data, defaults: UserDefaults) {
        removeLegacy(defaults: defaults)
        defaults.set(data, forKey: defaultsKey)
    }

    /// Removes only the legacy keys, leaving the current-version entry intact.
    /// Legacy `removeLegacyPersistedWindowGeometry(defaults:)`.
    public func removeLegacy(defaults: UserDefaults) {
        legacyDefaultsKeys.forEach { defaults.removeObject(forKey: $0) }
    }

    /// Encodes `payload` to its FROZEN JSON wire form, or nil on failure.
    /// Legacy `encodedPersistedWindowGeometryData`'s `try? JSONEncoder().encode`.
    public func encode(_ payload: Payload) -> Data? {
        try? JSONEncoder().encode(payload)
    }

    /// Decodes a geometry payload from `data`, gating on ``schemaVersion``.
    /// Returns nil for malformed data or a version mismatch. Legacy
    /// `decodedPersistedWindowGeometryData`.
    public func decode(_ data: Data) -> Payload? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == schemaVersion else {
            return nil
        }
        return payload
    }
}
