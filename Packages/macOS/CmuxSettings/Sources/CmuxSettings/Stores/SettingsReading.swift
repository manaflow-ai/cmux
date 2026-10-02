import Foundation

/// Synchronous, typed read access to `UserDefaults`-backed settings.
///
/// This is the read seam consumed by `@MainActor` model code that needs a
/// setting's current value inside a synchronous turn (selection side effects,
/// workspace creation, sidebar projection). The async
/// ``UserDefaultsSettingsStore`` actor remains the home for observation
/// (`values(for:)`) and for callers that can await; this protocol exists for
/// the call sites that cannot, where inserting a suspension point would
/// change user-observable interleavings.
///
/// Both paths share the same primitives — ``DefaultsKey`` for identity and
/// ``SettingCodable`` for the wire encoding — so a value written through one
/// is read identically through the other.
public protocol SettingsReading: Sendable {
    /// Returns the current value for the key, falling back to the key's
    /// default when no stored override decodes.
    func value<Value: SettingCodable>(for key: DefaultsKey<Value>) -> Value

    /// Returns the stored override for the key, or `nil` when the key has no
    /// stored value (or the stored value does not decode as `Value`).
    ///
    /// Use this when *absence* is meaningful — for example a legacy-migration
    /// fallback chain that only runs while the primary key has never been
    /// written. ``value(for:)`` cannot distinguish "absent" from "explicitly
    /// stored default".
    func valueIfPresent<Value: SettingCodable>(for key: DefaultsKey<Value>) -> Value?
}
