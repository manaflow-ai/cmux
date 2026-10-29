public import Foundation
import CryptoKit

/// A Curve25519 WireGuard key pair in the base64 form wg-quick expects.
///
/// The private half never leaves the device; only ``publicKey`` travels to
/// the control plane.
public struct WireGuardKeyPair: Sendable, Equatable {
    /// Base64 32-byte private key.
    public var privateKey: String
    /// Base64 32-byte public key derived from ``privateKey``.
    public var publicKey: String

    /// Generates a fresh key pair.
    public init() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        privateKey = key.rawRepresentation.base64EncodedString()
        publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Rebuilds a key pair from a stored private key, deriving the public half.
    /// - Parameter privateKey: Base64 32-byte private key.
    /// - Returns: Nil when the string is not a valid Curve25519 private key.
    public init?(privateKey: String) {
        guard let raw = Data(base64Encoded: privateKey.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count == 32,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
            return nil
        }
        self.privateKey = key.rawRepresentation.base64EncodedString()
        self.publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    }
}
