public import Foundation

/// A base64url-encoded byte string from a WebAuthn request payload, decoded into
/// `Data` at parse time.
public struct BrowserWebAuthnBinaryData: Decodable {
    /// The decoded bytes.
    public let data: Data

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let data = Data(base64URLEncoded: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid base64url-encoded WebAuthn binary value."
            )
        }
        self.data = data
    }
}
