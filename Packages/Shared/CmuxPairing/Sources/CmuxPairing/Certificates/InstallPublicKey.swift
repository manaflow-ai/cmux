public import CryptoKit
import Foundation

/// An install's P-256 public key as the backend records it (a JWK).
public struct InstallPublicKey: Hashable, Sendable, Codable {
    public var kty: String
    public var crv: String
    public var x: String
    public var y: String

    public init(kty: String = "EC", crv: String = "P-256", x: String, y: String) {
        self.kty = kty
        self.crv = crv
        self.x = x
        self.y = y
    }

    public init(_ key: P256.Signing.PublicKey) {
        let raw = key.rawRepresentation
        self.init(x: raw.prefix(32).base64URLEncodedString(), y: raw.suffix(32).base64URLEncodedString())
    }

    /// The CryptoKit key, or nil when the JWK is not a valid P-256 point.
    public var signingKey: P256.Signing.PublicKey? {
        guard kty == "EC", crv == "P-256", let px = Data(base64URLEncoded: x), let py = Data(base64URLEncoded: y),
              px.count == 32, py.count == 32 else { return nil }
        return try? P256.Signing.PublicKey(rawRepresentation: px + py)
    }
}
