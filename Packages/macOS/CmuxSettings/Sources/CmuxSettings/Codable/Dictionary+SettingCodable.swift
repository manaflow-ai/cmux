import Foundation

/// Dictionary ``SettingCodable`` conformance for string-keyed dictionaries
/// of conforming values.
///
/// Decode is all-or-nothing for the same reason as
/// ``Array+SettingCodable``: silent partial recovery hides corruption.
extension Dictionary: SettingCodable where Key == String, Value: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> [String: Value]? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        var result: [String: Value] = [:]
        result.reserveCapacity(dictionary.count)
        for (key, value) in dictionary {
            guard let decoded = Value.decodeFromUserDefaults(value) else { return nil }
            result[key] = decoded
        }
        return result
    }

    public func encodeForUserDefaults() -> Any { mapValues { $0.encodeForUserDefaults() } }

    public static func decodeFromJSON(_ raw: Any?) -> [String: Value]? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        var result: [String: Value] = [:]
        result.reserveCapacity(dictionary.count)
        for (key, value) in dictionary {
            guard let decoded = Value.decodeFromJSON(value) else { return nil }
            result[key] = decoded
        }
        return result
    }

    public func encodeForJSON() -> Any { mapValues { $0.encodeForJSON() } }
}
