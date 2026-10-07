public import CryptoKit
public import Foundation

/// An X25519 link key (or a DTLS fingerprint) signed by an install's Secure
/// Enclave P-256 key (b6-pairing.md section 2). The owner (UserDO) checks the
/// signature when it is published; every client checks it again before it
/// trusts the key, so the owner can hide a key but cannot forge one.
public struct LinkCertificate: Hashable, Sendable, Codable {
    public var purpose: LinkPurpose
    public var user: String
    public var install: String
    /// base64url of 32 bytes: the raw X25519 public key, or the SHA-256 DTLS fingerprint.
    public var key: String
    /// Milliseconds since 1970.
    public var issuedAt: Int64
    public var expiresAt: Int64
    /// ES256 raw r||s, base64url.
    public var signature: String

    public init(purpose: LinkPurpose, user: String, install: String, key: String, issuedAt: Int64, expiresAt: Int64, signature: String) {
        self.purpose = purpose
        self.user = user
        self.install = install
        self.key = key
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case purpose, user, install, key, signature
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
    }

    /// The 32 key bytes, when `key` is valid base64url of that length.
    public var keyBytes: Data? {
        guard let data = Data(base64URLEncoded: key), data.count == 32 else { return nil }
        return data
    }

    /// The exact bytes the install key signs (the backend's `linkCertMessage`).
    public static func signedMessage(environment: String, purpose: LinkPurpose, user: String, install: String,
                                     key: String, issuedAt: Int64, expiresAt: Int64) -> Data {
        Data(["cmux-link-cert/1", environment, user, install, purpose.rawValue, key, String(issuedAt), String(expiresAt)]
            .joined(separator: "\n").utf8)
    }

    public func signedMessage(environment: String) -> Data {
        Self.signedMessage(environment: environment, purpose: purpose, user: user, install: install, key: key,
                           issuedAt: issuedAt, expiresAt: expiresAt)
    }

    /// Checks shape, lifetime, expiry at `now` (milliseconds) and the signature
    /// by `installKey`. Throws the first failure.
    public func verify(installKey: P256.Signing.PublicKey, environment: String, now: Int64) throws(LinkCertificateError) {
        guard keyBytes != nil else { throw .badKey }
        guard expiresAt > issuedAt, expiresAt - issuedAt <= purpose.maxLifetimeMilliseconds else { throw .lifetimeTooLong }
        guard expiresAt > now else { throw .expired }
        guard issuedAt <= now + 5 * 60_000 else { throw .notYetValid }
        guard let raw = Data(base64URLEncoded: signature),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              installKey.isValidSignature(sig, for: signedMessage(environment: environment)) else { throw .badSignature }
    }
}
