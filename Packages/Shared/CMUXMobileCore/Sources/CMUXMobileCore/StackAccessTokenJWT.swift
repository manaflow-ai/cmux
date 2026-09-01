public import CryptoKit
public import Foundation

/// Local verification of Stack access tokens (ES256 JWTs) against the
/// project's published JWKS, so authorizing a session or request costs no
/// network round trip. Claim contract (mirrors the Stack backend's signer):
/// `sub` is the user id and `aud` is the project id; an `:anon` or
/// `:restricted` audience suffix marks a user class that must never be
/// authorized, so only the exact project id is accepted. `iss` is pinned to
/// the issuer the backend derives from its API base URL
/// (`<base>/api/v1/projects/<projectId>`, verified against a real token
/// 2026-08); callers compute the allow-set from their configured base URL
/// via `allowedIssuers(stackAPIBaseURL:projectID:)`.
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

    /// The `iss` values a token for `projectID` may carry, derived from the
    /// configured Stack API base URL the way the backend's `getIssuer`
    /// builds the claim for normal users: the base URL's origin plus the
    /// absolute path `/api/v1/projects/<projectID>`. Anonymous and
    /// restricted user types issue under `/projects-anonymous-users/` and
    /// `/projects-restricted-users/`; those users are already rejected by
    /// the audience check, so only the normal-user issuer is allowed. The
    /// stack-auth ↔ hexclave rebrand alias host is included (the backend's
    /// validator accepts both during the domain transition); the base URL
    /// itself always comes from the caller's configuration.
    public static func allowedIssuers(stackAPIBaseURL: URL, projectID: String) -> [String] {
        guard var components = URLComponents(url: stackAPIBaseURL, resolvingAgainstBaseURL: true) else {
            return []
        }
        components.path = "/api/v1/projects/\(projectID)"
        components.query = nil
        components.fragment = nil
        guard let primary = components.url?.absoluteString else { return [] }
        var issuers = [primary]
        if let host = components.host?.lowercased(),
           let alias = issuerHostAliases[host] {
            components.host = alias
            if let aliased = components.url?.absoluteString {
                issuers.append(aliased)
            }
        }
        return issuers
    }

    /// Stack-auth ↔ hexclave rebrand host pairs, mirroring the backend's
    /// `CLOUD_HOST_PAIRS` (`packages/shared/src/utils/cloud-hosts.tsx` in
    /// the Stack source).
    private static let issuerHostAliases: [String: String] = [
        "api.stack-auth.com": "api.hexclave.com",
        "api.hexclave.com": "api.stack-auth.com",
        "api.dev.stack-auth.com": "api.dev.hexclave.com",
        "api.dev.hexclave.com": "api.dev.stack-auth.com",
        "api.staging.stack-auth.com": "api.staging.hexclave.com",
        "api.staging.hexclave.com": "api.staging.stack-auth.com",
    ]

    /// Verifies `token` and returns its subject (the Stack user id).
    /// `allowedIssuers` is the pinned `iss` allow-set (see
    /// `allowedIssuers(stackAPIBaseURL:projectID:)`); `leewaySeconds`
    /// absorbs clock skew on `exp`.
    public static func verifiedUserID(
        token: String,
        keys: [JWK],
        projectID: String,
        allowedIssuers: [String],
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
        // Issuer pinned to the configured Stack API base; a mismatch (or a
        // missing claim) is definitive.
        guard let iss = payload.iss, allowedIssuers.contains(iss) else {
            throw VerificationError.invalid("issuer mismatch")
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
        let iss: String?
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
