/// The backend-signed pair grant proving admission on the control lane.
///
/// v3 admits online-issued pair grants only. The legacy offline-pairing
/// credential is deferred together with offline first-pair; offline
/// *re*-connect still uses a cached pair grant and rides this same shape.
public struct PeerPairGrantCredential: Equatable, Sendable {
    /// A compact EdDSA JWS, 5 bytes through 12 KiB.
    public let token: String

    /// Creates a validated pair-grant credential.
    ///
    /// - Parameter token: A compact JWS (three non-empty base64url segments).
    /// - Throws: ``PeerPairGrantCredentialError/invalidSignedToken`` for malformed input.
    public init(token: String) throws {
        guard Self.isValidCompactJWS(token) else {
            throw PeerPairGrantCredentialError.invalidSignedToken
        }
        self.token = token
    }

    private static func isValidCompactJWS(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (5 ... 12 * 1_024).contains(bytes.count) else { return false }
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else { return false }
        return segments.joined().utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
                 UInt8(ascii: "a") ... UInt8(ascii: "z"),
                 UInt8(ascii: "0") ... UInt8(ascii: "9"),
                 UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }
}

/// Validation failures for a pair-grant admission credential.
public enum PeerPairGrantCredentialError: Error, Equatable, Sendable {
    /// The token is not a bounded compact JWS.
    case invalidSignedToken
}
