import Foundation

/// URL ``SettingCodable`` conformance — encodes as an absolute-string in
/// both backends.
extension URL: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> URL? {
        guard let string = raw as? String else { return nil }
        return URL(string: string)
    }

    public func encodeForUserDefaults() -> Any { absoluteString }

    public static func decodeFromJSON(_ raw: Any?) -> URL? {
        guard let string = raw as? String else { return nil }
        return URL(string: string)
    }

    public func encodeForJSON() -> Any { absoluteString }
}
