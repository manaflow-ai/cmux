import Foundation

/// An opaque flow-control nonce carried by `ack-request` and `ack`.
///
/// The relay contract allows 1...64 UTF-8 bytes and rejects Unicode control
/// characters. Keeping validation in the value type prevents an invalid nonce
/// from entering either wire case.
public struct ShareAckNonce: Hashable, RawRepresentable, Sendable {
    /// Maximum encoded UTF-8 byte count.
    public static let maximumUTF8Bytes = 64

    /// The validated opaque value.
    public let rawValue: String

    /// Creates a nonce when `rawValue` satisfies the wire contract.
    public init?(rawValue: String) {
        let byteCount = rawValue.utf8.count
        guard byteCount > 0,
              byteCount <= Self.maximumUTF8Bytes,
              rawValue.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        self.rawValue = rawValue
    }
}

extension ShareAckNonce: Codable {
    /// Decodes and validates a nonce from its single JSON string value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let nonce = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid workspace-share acknowledgement nonce."
            )
        }
        self = nonce
    }

    /// Encodes the opaque nonce as a JSON string.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
