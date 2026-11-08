import Foundation

/// One pinned Ed25519 public key accepted for managed-relay policy signatures.
public struct CmxIrohRelayPolicyVerificationKey: Equatable, Sendable {
    /// The bounded JWS key identifier.
    public let keyID: String

    /// The canonical standard-Base64 encoding of the 32-byte Ed25519 public key.
    public let rawPublicKeyBase64: String

    /// Creates one pinned relay-policy verification key.
    ///
    /// - Parameters:
    ///   - keyID: The `kid` accepted in a relay-policy JWS header.
    ///   - rawPublicKeyBase64: A canonical Base64-encoded Ed25519 public key.
    /// - Throws: ``CmxIrohRelayPolicyError/invalidTrustRoot`` for malformed input.
    public init(keyID: String, rawPublicKeyBase64: String) throws {
        guard Self.isSafeKeyID(keyID),
              let key = Data(base64Encoded: rawPublicKeyBase64),
              key.count == 32,
              key.base64EncodedString() == rawPublicKeyBase64 else {
            throw CmxIrohRelayPolicyError.invalidTrustRoot
        }
        self.keyID = keyID
        self.rawPublicKeyBase64 = rawPublicKeyBase64
    }

    var rawPublicKey: Data {
        Data(base64Encoded: rawPublicKeyBase64)!
    }

    static func isSafeKeyID(_ value: String) -> Bool {
        guard (1 ... 64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || [45, 46, 95].contains(byte)
        }
    }
}
