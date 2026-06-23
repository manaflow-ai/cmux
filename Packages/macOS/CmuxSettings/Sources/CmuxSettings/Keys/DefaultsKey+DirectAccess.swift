import Foundation

/// Synchronous, catalog-typed access to a `DefaultsKey`'s value in a
/// `UserDefaults` suite.
///
/// This is the read/write seam for call paths that cannot await — AppKit
/// event handlers, quit/close policy checks, socket command handlers, and
/// other synchronous non-SwiftUI code. It uses the exact same
/// ``SettingCodable`` decode/encode as ``UserDefaultsSettingsStore`` (the
/// store's own accessors forward here), so the catalog stays the single
/// definition of key string, value type, decode, and default.
///
/// Pick the right access path per driver:
/// - SwiftUI views: `@LiveSetting` (reactive, host-agnostic).
/// - Async code that also observes changes: ``UserDefaultsSettingsStore``.
/// - Synchronous code: these accessors.
///
/// `UserDefaults` is documented thread-safe, so these calls are safe from any
/// thread; they provide no change observation.
extension DefaultsKey {
    /// Returns the current value for this key in `defaults`, falling back to
    /// ``defaultValue`` when no override is stored or the stored value does
    /// not decode as `Value`.
    public func value(in defaults: UserDefaults) -> Value {
        Value.decodeFromUserDefaults(defaults.object(forKey: userDefaultsKey)) ?? defaultValue
    }

    /// Writes `value` for this key into `defaults`.
    public func set(_ value: Value, in defaults: UserDefaults) {
        defaults.set(value.encodeForUserDefaults(), forKey: userDefaultsKey)
    }

    /// Removes the stored override for this key from `defaults`. After this
    /// call ``value(in:)`` returns ``defaultValue`` until something writes a
    /// new override.
    public func removeValue(in defaults: UserDefaults) {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    /// Whether `defaults` holds any stored object for this key, decodable or
    /// not. Lets legacy fallback chains distinguish "never set" from "set".
    public func hasStoredValue(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: userDefaultsKey) != nil
    }
}
