import Foundation

/// The install's P-256 key. The private half never leaves the signer (the
/// Secure Enclave on a device); only the public point and signatures do.
public protocol InstallSigner: Sendable {
    /// Uncompressed public point (X9.63: 0x04 || x || y, 65 bytes).
    func publicKeyX963() async throws -> Data
    /// ES256 over `message` (SHA-256 inside), raw r||s (64 bytes) or DER.
    func sign(_ message: Data) async throws -> Data
    /// Replaces the key (a revoked install, or a key the owner already holds
    /// for another install). The old private key is destroyed.
    func rotate() async throws
}

public enum InstallAuthError: Error, Hashable, Sendable {
    case invalidPublicKey
    case noSession
    case refused(String)
    /// The owner sent a challenge this client will not sign.
    case unexpectedChallenge
    /// `user.ensure` answered for a different Stack user than the session's.
    case userMismatch
    case transport
    case malformedReply
    /// The team requires a newer app (`updates.minimumVersion`); the owner
    /// names the minimum. Not an install problem: the key and record stay,
    /// and the same install mints again once the app is updated.
    case clientTooOld(minimumVersion: String?)
}

/// The public JWK the owner stores for the install.
public struct PublicJWK: Hashable, Sendable {
    public var x: String
    public var y: String

    public init(x963: Data) throws {
        guard x963.count == 65, x963.first == 0x04 else { throw InstallAuthError.invalidPublicKey }
        x = (x963.subdata(in: 1..<33)).base64URLEncoded
        y = (x963.subdata(in: 33..<65)).base64URLEncoded
    }

    public var json: [String: String] { ["kty": "EC", "crv": "P-256", "x": x, "y": y] }
}

extension Data {
    /// base64url without padding (RFC 4648 section 5).
    public var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decodes base64url with or without padding.
    public init?(base64URLEncoded text: String) {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        self.init(base64Encoded: base)
    }
}
