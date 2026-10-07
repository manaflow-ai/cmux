import Foundation

/// Free ``SettingCodable`` conformance for `RawRepresentable` types whose
/// raw value is itself ``SettingCodable``.
///
/// Most cmux value enums use a `String` raw value, so adding `: SettingCodable`
/// to their declaration is enough to make them storable:
///
/// ```swift
/// public enum AppearanceMode: String, CaseIterable, Sendable, SettingCodable {
///     case system, light, dark
/// }
/// ```
///
/// The default implementation forwards encode/decode through the raw value's
/// own ``SettingCodable`` conformance, so the enum gains the same UserDefaults
/// and JSON round-trip behavior as its `RawValue`.
extension SettingCodable where Self: RawRepresentable, Self.RawValue: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> Self? {
        RawValue.decodeFromUserDefaults(raw).flatMap { Self(rawValue: $0) }
    }

    public func encodeForUserDefaults() -> Any { rawValue.encodeForUserDefaults() }

    public static func decodeFromJSON(_ raw: Any?) -> Self? {
        RawValue.decodeFromJSON(raw).flatMap { Self(rawValue: $0) }
    }

    public func encodeForJSON() -> Any { rawValue.encodeForJSON() }
}
