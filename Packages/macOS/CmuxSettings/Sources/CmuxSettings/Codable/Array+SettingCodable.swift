import Foundation

/// Array ``SettingCodable`` conformance for arrays of conforming elements.
///
/// Decode is all-or-nothing: if any element fails to decode, the whole
/// array returns `nil` and the store falls back to the key's default.
/// Partial recovery would silently hide single-element corruption.
extension Array: SettingCodable where Element: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> [Element]? {
        guard let array = raw as? [Any] else { return nil }
        var result: [Element] = []
        result.reserveCapacity(array.count)
        for element in array {
            guard let value = Element.decodeFromUserDefaults(element) else { return nil }
            result.append(value)
        }
        return result
    }

    public func encodeForUserDefaults() -> Any { map { $0.encodeForUserDefaults() } }

    public static func decodeFromJSON(_ raw: Any?) -> [Element]? {
        guard let array = raw as? [Any] else { return nil }
        var result: [Element] = []
        result.reserveCapacity(array.count)
        for element in array {
            guard let value = Element.decodeFromJSON(element) else { return nil }
            result.append(value)
        }
        return result
    }

    public func encodeForJSON() -> Any { map { $0.encodeForJSON() } }
}
