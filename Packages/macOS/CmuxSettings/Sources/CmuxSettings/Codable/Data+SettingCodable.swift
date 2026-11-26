import Foundation

/// Binary ``Data`` ``SettingCodable`` conformance.
///
/// UserDefaults stores `Data` natively. JSON has no native binary type, so
/// the value round-trips through a Base64 string when the backing store is
/// ``SettingBackend/jsonConfig``.
extension Data: SettingCodable {
    public static func decodeFromUserDefaults(_ raw: Any?) -> Data? { raw as? Data }
    public func encodeForUserDefaults() -> Any { self }

    /// Decodes binary data from a Base64 string.
    ///
    /// JSON has no native binary type, so ``Data`` round-trips through Base64
    /// when the backing store is ``SettingBackend/jsonConfig``.
    public static func decodeFromJSON(_ raw: Any?) -> Data? {
        guard let string = raw as? String else { return nil }
        return Data(base64Encoded: string)
    }

    public func encodeForJSON() -> Any { base64EncodedString() }
}
