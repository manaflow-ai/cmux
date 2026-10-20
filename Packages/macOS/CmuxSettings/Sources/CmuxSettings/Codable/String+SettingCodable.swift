import Foundation

/// String ``SettingCodable`` conformance — passthrough on both backends.
extension String: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> String? { raw as? String }
    public func encodeForUserDefaults() -> Any { self }

    public static func decodeFromJSON(_ raw: Any?) -> String? { raw as? String }
    public func encodeForJSON() -> Any { self }
}
