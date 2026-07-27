import Foundation

/// The synchronous `UserDefaults`-backed conformer to ``SettingsWriting``.
///
/// A stateless value wrapping one `UserDefaults` suite. `UserDefaults` is
/// documented thread-safe, so the client is freely `Sendable`; reads and
/// writes go straight through with no caching layer, which keeps the client
/// byte-equivalent to a direct `UserDefaults.standard` read at every call
/// site that migrates onto it.
///
/// Construct one at the composition root and inject it; tests pass a scoped
/// `UserDefaults(suiteName:)`.
///
/// ```swift
/// let settings = UserDefaultsSettingsClient(defaults: .standard)
/// let hideAll = settings.value(for: catalog.sidebar.hideAllDetails)
/// ```
///
/// Legacy-key migration (``DefaultsKey/legacyUserDefaultsKeys``) is the
/// ``UserDefaultsSettingsStore`` actor's init-time concern; this client reads
/// the primary key only.
public struct UserDefaultsSettingsClient: SettingsWriting {
    // UserDefaults is documented thread-safe; the SDK just has not annotated
    // it Sendable, so the one stored property carries the justification
    // instead of the whole type going @unchecked Sendable.
    private nonisolated(unsafe) let defaults: UserDefaults

    /// Creates a client over the given `UserDefaults` suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func value<Value: SettingCodable>(for key: DefaultsKey<Value>) -> Value {
        Value.decodeFromUserDefaults(defaults.object(forKey: key.userDefaultsKey)) ?? key.defaultValue
    }

    public func valueIfPresent<Value: SettingCodable>(for key: DefaultsKey<Value>) -> Value? {
        Value.decodeFromUserDefaults(defaults.object(forKey: key.userDefaultsKey))
    }

    public func set<Value: SettingCodable>(_ value: Value, for key: DefaultsKey<Value>) {
        defaults.set(value.encodeForUserDefaults(), forKey: key.userDefaultsKey)
    }

    public func reset<Value: SettingCodable>(_ key: DefaultsKey<Value>) {
        defaults.removeObject(forKey: key.userDefaultsKey)
    }
}
