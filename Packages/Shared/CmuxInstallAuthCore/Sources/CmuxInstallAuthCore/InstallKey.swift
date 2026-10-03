import Foundation

/// The install's P-256 key. The private half never leaves the signer (the
/// Secure Enclave on a device); only the public point and signatures do.
public protocol InstallSigner: Sendable {
    /// Uncompressed public point (X9.63: 0x04 || x || y, 65 bytes).
    func publicKeyX963() async throws -> Data
    /// ES256 over `message` (SHA-256 inside), raw r||s (64 bytes) or DER.
    func sign(_ message: Data) async throws -> Data
}

public enum InstallAuthError: Error, Hashable, Sendable {
    case invalidPublicKey
    case noSession
    case refused(String)
    case transport
    case malformedReply
}

/// The public JWK the owner stores for the install.
public struct PublicJWK: Hashable, Sendable {
    public var x: String
    public var y: String

    public init(x963: Data) throws {
        guard x963.count == 65, x963.first == 0x04 else { throw InstallAuthError.invalidPublicKey }
        x = Base64URL.encode(x963.subdata(in: 1..<33))
        y = Base64URL.encode(x963.subdata(in: 33..<65))
    }

    public var json: [String: String] { ["kty": "EC", "crv": "P-256", "x": x, "y": y] }
}

/// base64url without padding (RFC 4648 section 5).
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: String) -> Data? {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        return Data(base64Encoded: base)
    }
}
