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
    /// The request to `path` got no HTTP answer; `urlErrorCode` is the
    /// transport's `URLError` code when it threw one (-1001: timed out).
    case transport(path: String, urlErrorCode: Int?)
    case malformedReply
    /// The team requires a newer app (`updates.minimumVersion`); the owner
    /// names the minimum. Not an install problem: the key and record stay,
    /// and the same install mints again once the app is updated.
    case clientTooOld(minimumVersion: String?)
}

/// What a log line or a relay answer says of a failed mint: the step and its code. Never a token.
extension InstallAuthError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidPublicKey: "the install key is not a P-256 point"
        case .noSession: "no sign-in session to register the install with"
        case .refused(let code): "the cmux API refused the install token request (\(code))"
        case .unexpectedChallenge: "the cmux API sent a challenge this install will not sign"
        case .userMismatch: "the cmux API answered for another user"
        case .transport(let path, let code):
            "POST \(path) got no answer" + (code.map { " (URLError \($0))" } ?? "")
        case .malformedReply: "the cmux API answered the install token request with no token"
        case .clientTooOld(let minimum): "this cmux is too old for the team" + (minimum.map { " (needs \($0))" } ?? "")
        }
    }
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
