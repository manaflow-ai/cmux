public import Foundation

/// base64url (RFC 4648 §5, unpadded) coding used throughout the WebAuthn bridge
/// to move credential bytes between native `Data` and the page-world strings.
extension Data {
    /// Decodes an unpadded base64url string into bytes, returning nil on invalid input.
    public init?(base64URLEncoded encoded: String) {
        let normalized = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - normalized.count % 4) % 4
        let padded = normalized + String(repeating: "=", count: paddingLength)
        self.init(base64Encoded: padded)
    }

    /// Encodes the bytes as an unpadded base64url string.
    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
