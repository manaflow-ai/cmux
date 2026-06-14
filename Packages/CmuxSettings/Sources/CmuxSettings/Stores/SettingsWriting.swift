import Foundation

/// Synchronous, typed write access to `UserDefaults`-backed settings.
///
/// Extends ``SettingsReading`` with the write half so call sites that own a
/// setting's mutation path (toggles, "don't ask again" suppression flags)
/// can be injected with one collaborator. Writes encode through the key's
/// ``SettingCodable`` conformance, identically to
/// ``UserDefaultsSettingsStore/set(_:for:)``.
public protocol SettingsWriting: SettingsReading {
    /// Writes a value for the key.
    func set<Value: SettingCodable>(_ value: Value, for key: DefaultsKey<Value>)

    /// Removes the stored override for the key. After this call
    /// ``SettingsReading/value(for:)`` returns the key's default value until
    /// something writes a new override.
    func reset<Value: SettingCodable>(_ key: DefaultsKey<Value>)
}
