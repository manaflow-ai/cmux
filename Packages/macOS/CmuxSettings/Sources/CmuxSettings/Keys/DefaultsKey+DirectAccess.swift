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
    /// Returns the current value for this key in `defaults`.
    ///
    /// A decodable user value wins over a decodable cached remote default,
    /// followed by ``defaultValue``.
    public func value(in defaults: UserDefaults) -> Value {
        resolution(in: defaults).value
    }

    /// Returns the value and the layer that supplied it.
    public func resolution(in defaults: UserDefaults) -> DefaultsValueResolution<Value> {
        if let value = Value.decodeFromUserDefaults(defaults.object(forKey: userDefaultsKey)) {
            return DefaultsValueResolution(value: value, source: .user)
        }
        if let remoteDefaultUserDefaultsKey,
           let value = Value.decodeFromUserDefaults(defaults.object(forKey: remoteDefaultUserDefaultsKey)) {
            return DefaultsValueResolution(value: value, source: .remoteDefault)
        }
        return DefaultsValueResolution(value: defaultValue, source: .compileDefault)
    }

    /// Returns the value inherited after removing the explicit user choice.
    public func inheritedValue(in defaults: UserDefaults) -> Value {
        if let remoteDefaultUserDefaultsKey,
           let value = Value.decodeFromUserDefaults(defaults.object(forKey: remoteDefaultUserDefaultsKey)) {
            return value
        }
        return defaultValue
    }

    /// Returns the decodable cached remote default, if this key has one.
    public func remoteDefaultValue(in defaults: UserDefaults) -> Value? {
        guard let remoteDefaultUserDefaultsKey else { return nil }
        return Value.decodeFromUserDefaults(defaults.object(forKey: remoteDefaultUserDefaultsKey))
    }

    /// Writes `value` for this key into `defaults`.
    public func set(_ value: Value, in defaults: UserDefaults) {
        defaults.set(value.encodeForUserDefaults(), forKey: userDefaultsKey)
    }

    /// Removes the stored user override for this key from `defaults`. After
    /// this call ``value(in:)`` resolves the cached remote default when one
    /// exists, otherwise ``defaultValue``.
    public func removeValue(in defaults: UserDefaults) {
        defaults.removeObject(forKey: userDefaultsKey)
    }

    /// Updates only the cached remote-default layer.
    ///
    /// Returns whether storage changed. An unchanged value is silent, which
    /// keeps periodic remote refreshes from invalidating settings views.
    @discardableResult
    public func setRemoteDefault(
        _ value: Value?,
        in defaults: UserDefaults,
        notificationCenter: NotificationCenter = .default
    ) -> Bool {
        guard let remoteDefaultUserDefaultsKey else { return false }
        if let value {
            guard Value.decodeFromUserDefaults(
                defaults.object(forKey: remoteDefaultUserDefaultsKey)
            ) != value else {
                return false
            }
        } else {
            guard defaults.object(forKey: remoteDefaultUserDefaultsKey) != nil else {
                return false
            }
        }

        notificationCenter.post(
            name: .cmuxSettingsRemoteDefaultWillChange,
            object: defaults,
            userInfo: [
                CmuxSettingsRemoteDefaultNotification.storageKeyUserInfoKey: userDefaultsKey,
            ]
        )

        if let value {
            defaults.set(value.encodeForUserDefaults(), forKey: remoteDefaultUserDefaultsKey)
        } else {
            defaults.removeObject(forKey: remoteDefaultUserDefaultsKey)
        }

        notificationCenter.post(
            name: .cmuxSettingsRemoteDefaultDidChange,
            object: defaults,
            userInfo: [
                CmuxSettingsRemoteDefaultNotification.storageKeyUserInfoKey: userDefaultsKey,
            ]
        )
        return true
    }

    /// Whether `defaults` holds any stored object for this key, decodable or
    /// not. Lets legacy fallback chains distinguish "never set" from "set".
    public func hasStoredValue(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: userDefaultsKey) != nil
    }
}

public extension Notification.Name {
    /// Posted immediately before a typed remote-default cache mutation.
    static let cmuxSettingsRemoteDefaultWillChange =
        Notification.Name("cmux.settings.remoteDefaultWillChange")

    /// Posted after a typed remote-default cache value changes.
    static let cmuxSettingsRemoteDefaultDidChange =
        Notification.Name("cmux.settings.remoteDefaultDidChange")
}

enum CmuxSettingsRemoteDefaultNotification {
    static let storageKeyUserInfoKey = "storageKey"
}
