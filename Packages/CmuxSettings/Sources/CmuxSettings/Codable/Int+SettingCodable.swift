import Foundation

/// Integer ``SettingCodable`` conformance.
///
/// JSON decode rejects boolean-typed numerics (`true`/`false`) and any
/// fractional double — the value must be exactly integral. UserDefaults
/// decode is more lenient and accepts any numeric-shaped object.
extension Int: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue
        }
        return nil
    }

    public func encodeForUserDefaults() -> Any { self }

    /// Decodes an integer from JSON, rejecting boolean numerics and fractional doubles.
    ///
    /// `JSONSerialization` represents both booleans and numbers as `NSNumber`.
    /// This implementation distinguishes the two using `CFBooleanGetTypeID` so
    /// `true` is not silently coerced to `1`. Doubles whose value is not
    /// exactly representable as an `Int` are rejected.
    public static func decodeFromJSON(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        guard double.rounded() == double else { return nil }
        return number.intValue
    }

    public func encodeForJSON() -> Any { self }
}
