import Foundation

/// A value that can round-trip through both `UserDefaults` and the cmux JSON config file.
///
/// Conformers describe how to read themselves from the loose `Any` representations
/// produced by `UserDefaults` and `JSONSerialization`, and how to write themselves
/// back as values those same APIs accept (`Bool`, `Int`, `Double`, `String`,
/// `Data`, `[Any]`, `[String: Any]`, or `NSNumber`).
///
/// Built-in conformances live next to this protocol in
/// `Bool+SettingCodable.swift`, `Int+SettingCodable.swift`, and so on. They
/// cover `Bool`, `Int`, `Double`, `String`, `Data`, `URL`, arrays and string
/// dictionaries of conforming elements, and every `RawRepresentable` whose
/// raw value is itself ``SettingCodable``.
///
/// Add a new conformance when introducing a value type that does not reduce to
/// one of the above (for example a struct stored as a nested JSON object).
///
/// ```swift
/// extension AppearanceMode: SettingCodable {}
/// // RawRepresentable enums pick up the default implementation for free.
/// ```
public protocol SettingCodable: Sendable, Equatable {
    /// Decodes a value from a property-list representation produced by `UserDefaults`.
    ///
    /// - Parameter raw: A value returned by `UserDefaults.object(forKey:)`, or
    ///   `nil` when the key has no override.
    /// - Returns: The decoded value, or `nil` when `raw` is `nil` or has an
    ///   unexpected shape. The store falls back to the key's default value on
    ///   `nil`.
    static func decodeFromUserDefaults(_ raw: Any?) -> Self?

    /// Encodes a value for storage in `UserDefaults`.
    ///
    /// - Returns: A property-list compatible value (`Bool`, `Int`, `Double`,
    ///   `String`, `Data`, or arrays/dictionaries of those).
    func encodeForUserDefaults() -> Any

    /// Decodes a value from the loose representation produced by `JSONSerialization`.
    ///
    /// - Parameter raw: A value found at the setting's JSON path, or `nil` when
    ///   the path is absent.
    /// - Returns: The decoded value, or `nil` when `raw` is `nil` or has an
    ///   unexpected shape.
    static func decodeFromJSON(_ raw: Any?) -> Self?

    /// Encodes a value for storage in the cmux JSON config file.
    ///
    /// - Returns: A `JSONSerialization`-compatible value.
    func encodeForJSON() -> Any
}
