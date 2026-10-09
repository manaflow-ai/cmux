public import Foundation
import CryptoKit

/// An install's P-256 identity public key (X9.63, 65 bytes), pinned at
/// pairing. Verifies fingerprint-binding signatures.
public struct WebRTCPublicKey: Sendable, Hashable, CustomStringConvertible {
    public let x963Representation: Data

    /// Builds a key from CryptoKit's already validated representation. This
    /// avoids turning an impossible CryptoKit invariant into a process trap in
    /// software identity construction.
    init(cryptoKitKey: P256.Signing.PublicKey) {
        self.x963Representation = cryptoKitKey.x963Representation
    }

    public init?(x963Representation: Data) {
        guard (try? P256.Signing.PublicKey(x963Representation: x963Representation)) != nil else { return nil }
        self.x963Representation = Data(x963Representation)
    }

    /// Standard or URL-safe base64, padding optional.
    public init?(base64: String) {
        var text = base64.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text.append("=") }
        guard let data = Data(base64Encoded: text) else { return nil }
        self.init(x963Representation: data)
    }

    public var base64: String { x963Representation.base64EncodedString() }

    public var description: String { "WebRTCPublicKey(\(base64.prefix(16))...)" }

    /// ECDSA P-256 SHA-256 over `message`, signature raw `r || s`.
    public func isValidSignature(_ signature: Data, for message: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: x963Representation),
              let ecdsa = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(ecdsa, for: message)
    }
}
