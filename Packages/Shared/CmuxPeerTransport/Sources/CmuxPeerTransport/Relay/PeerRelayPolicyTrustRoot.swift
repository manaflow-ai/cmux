import Foundation

/// One pinned Ed25519 public key accepted for managed-relay policy signatures.
public struct PeerRelayPolicyVerificationKey: Equatable, Sendable {
    /// The bounded JWS key identifier.
    public let keyID: String

    /// The canonical standard-Base64 encoding of the 32-byte Ed25519 public key.
    public let rawPublicKeyBase64: String

    /// Creates one pinned relay-policy verification key.
    ///
    /// - Parameters:
    ///   - keyID: The `kid` accepted in a relay-policy JWS header.
    ///   - rawPublicKeyBase64: A canonical Base64-encoded Ed25519 public key.
    /// - Throws: ``PeerRelayPolicyError/invalidTrustRoot`` for malformed input.
    public init(keyID: String, rawPublicKeyBase64: String) throws {
        guard Self.isSafeKeyID(keyID),
              let key = Data(base64Encoded: rawPublicKeyBase64),
              key.count == 32,
              key.base64EncodedString() == rawPublicKeyBase64 else {
            throw PeerRelayPolicyError.invalidTrustRoot
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

/// Immutable public keys pinned by the app for relay-policy verification.
///
/// Signed policies are the only path by which relay origins reach the
/// endpoint; the trust root is compiled into the app (Info.plist entries
/// substituted from `config/IrohRelayPolicy*.xcconfig`) and never supplied by
/// a policy response.
public struct PeerRelayPolicyTrustRoot: Equatable, Sendable {
    /// The current and staged-next keys accepted during rotation.
    public let keys: [PeerRelayPolicyVerificationKey]

    /// Creates a bounded relay-policy trust root.
    ///
    /// A release may pin a current key and staged replacements. Routine policy
    /// changes therefore do not pin relay URLs or require an app update.
    ///
    /// - Parameter keys: Between one and four unique Ed25519 verification keys.
    /// - Throws: ``PeerRelayPolicyError/invalidTrustRoot`` for an invalid set.
    public init(keys: [PeerRelayPolicyVerificationKey]) throws {
        guard (1 ... 4).contains(keys.count),
              Set(keys.map(\.keyID)).count == keys.count else {
            throw PeerRelayPolicyError.invalidTrustRoot
        }
        self.keys = keys
    }

    /// Reads the current and staged-next public keys from an app information
    /// dictionary.
    ///
    /// The plist key names are unchanged from the legacy transport so
    /// existing build configuration keeps working: the array form
    /// `CMUXIrohRelayPolicyTrustKeys` is authoritative, and the single-key
    /// form (`CMUXIrohRelayPolicyKeyID` + `CMUXIrohRelayPolicyPublicKeyBase64`)
    /// remains supported for already-shipped configurations. Any malformed
    /// entry fails the whole root closed.
    public static func appPinned(
        infoDictionary: [String: Any]?
    ) -> PeerRelayPolicyTrustRoot? {
        let records: [[String: String]]
        if let configured = infoDictionary?["CMUXIrohRelayPolicyTrustKeys"]
            as? [[String: String]] {
            records = configured
        } else if let keyID = infoDictionary?["CMUXIrohRelayPolicyKeyID"] as? String,
                  let publicKey = infoDictionary?["CMUXIrohRelayPolicyPublicKeyBase64"]
                    as? String {
            records = [["keyID": keyID, "publicKeyBase64": publicKey]]
        } else {
            return nil
        }
        let keys = records.compactMap { record -> PeerRelayPolicyVerificationKey? in
            guard let keyID = record["keyID"],
                  let publicKey = record["publicKeyBase64"] else { return nil }
            return try? PeerRelayPolicyVerificationKey(
                keyID: keyID,
                rawPublicKeyBase64: publicKey
            )
        }
        guard keys.count == records.count else { return nil }
        return try? PeerRelayPolicyTrustRoot(keys: keys)
    }

    func key(id: String) -> PeerRelayPolicyVerificationKey? {
        keys.first { $0.keyID == id }
    }
}
