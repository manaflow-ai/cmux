public import CryptoKit
public import Foundation

/// Local verification of Stack access tokens (ES256 JWTs) against the
/// project's published JWKS, so authorizing a session or request costs no
/// network round trip. Claim contract (mirrors the Stack backend's signer):
/// `sub` is the user id and `aud` is the project id; an `:anon` or
/// `:restricted` audience suffix marks a user class that must never be
/// authorized, so only the exact project id is accepted.
public enum StackAccessTokenJWT {
    public struct JWK: Decodable, Sendable {
        public let kty: String
        public let crv: String?
        public let x: String?
        public let y: String?
        public let kid: String?

        public init(kty: String, crv: String?, x: String?, y: String?, kid: String?) {
            self.kty = kty
            self.crv = crv
            self.x = x
            self.y = y
            self.kid = kid
        }
    }

    public struct JWKS: Decodable, Sendable {
        public let keys: [JWK]

        public init(keys: [JWK]) {
            self.keys = keys
        }
    }

    public enum VerificationError: Error, Equatable, Sendable {
        /// The string is not structurally a JWT; the caller may fall back to
        /// a network verification for opaque token formats.
        case notAJWT
        /// The token names a signing key the provided set does not contain;
        /// the caller should refetch the JWKS once (key rotation) and retry.
        case unknownKeyID
        /// Definitive: bad signature, wrong audience, expired, or malformed
        /// claims. Never retried.
        case invalid(String)
    }

    /// Verifies `token` and returns its subject (the Stack user id).
    /// `leewaySeconds` absorbs clock skew on `exp`.
    public static func verifiedUserID(
        token: String,
        keys: [JWK],
        projectID: String,
        now: Date = Date(),
        leewaySeconds: TimeInterval = 60
    ) throws -> String {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard token.hasPrefix("ey"), segments.count == 3 else {
            throw VerificationError.notAJWT
        }
        guard let headerData = base64URLDecode(segments[0]),
              let header = try? JSONDecoder().decode(Header.self, from: headerData) else {
            throw VerificationError.notAJWT
        }
        guard header.alg == "ES256" else {
            throw VerificationError.invalid("unsupported alg \(header.alg)")
        }
        guard let key = keys.first(where: { $0.kid == header.kid }) else {
            throw VerificationError.unknownKeyID
        }
        guard key.kty == "EC", key.crv == "P-256",
              let xData = key.x.flatMap({ base64URLDecode(Substring($0)) }),
              let yData = key.y.flatMap({ base64URLDecode(Substring($0)) }),
              xData.count == 32, yData.count == 32 else {
            throw VerificationError.invalid("unsupported JWK")
        }
        var x963 = Data([0x04])
        x963.append(xData)
        x963.append(yData)
        guard let publicKey = try? P256.Signing.PublicKey(x963Representation: x963) else {
            throw VerificationError.invalid("bad public key")
        }
        guard let signatureData = base64URLDecode(segments[2]),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData) else {
            throw VerificationError.invalid("bad signature encoding")
        }
        let signedBytes = Data("\(segments[0]).\(segments[1])".utf8)
        guard publicKey.isValidSignature(signature, for: SHA256.hash(data: signedBytes)) else {
            throw VerificationError.invalid("signature mismatch")
        }
        guard let payloadData = base64URLDecode(segments[1]),
              let payload = try? JSONDecoder().decode(Claims.self, from: payloadData) else {
            throw VerificationError.invalid("bad claims")
        }
        // Exact project id only: suffixe audiences are rejected user classes.
        guard payload.aud == projectID else {
            throw VerificationError.invalid("audience mismatch")
        }
        guard payload.exp + leewaySeconds > now.timeIntervalSince1970 else {
            throw VerificationError.invalid("expired")
        }
        guard !payload.sub.isEmpty else {
            throw VerificationError.invalid("empty subject")
        }
        return payload.sub
    }

    private struct Header: Decodable {
        let alg: String
        let kid: String?
    }

    private struct Claims: Decodable {
        let sub: String
        let aud: String
        let exp: TimeInterval
    }

    static func base64URLDecode(_ input: Substring) -> Data? {
        var base64 = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }
}
