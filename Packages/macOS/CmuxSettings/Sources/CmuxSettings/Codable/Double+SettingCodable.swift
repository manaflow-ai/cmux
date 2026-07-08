import Foundation

/// Double ``SettingCodable`` conformance.
///
/// Both backends accept any numeric-shaped `NSNumber` that is not a
/// `CFBoolean`. Integers widen to `Double` without loss.
extension Double: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> Double? {
        if let double = raw as? Double { return double }
        if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        return nil
    }

    public func encodeForUserDefaults() -> Any { self }

    public static func decodeFromJSON(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.doubleValue
    }

    public func encodeForJSON() -> Any { self }
}
