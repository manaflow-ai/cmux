internal import CryptoKit
public import Foundation

/// Issues and verifies opaque bearer capabilities for cmux-created terminals.
///
/// An authority is immutable and contains no session registry. Tokens issued
/// from the same secret and audience remain valid across listener and app
/// restarts, while a different app variant derives an independent signing key.
public struct SocketClientCapabilityAuthority: Sendable {
    /// Required byte count for master secrets and per-token nonces.
    public static let secureByteCount = 32

    private let signingKey: SymmetricKey

    /// Creates an audience-scoped capability authority.
    ///
    /// - Parameters:
    ///   - secret: Persistent random master secret. At least 32 bytes is recommended.
    ///   - audience: Stable app-variant identifier, normally the bundle identifier.
    public init(secret: Data, audience: String) {
        let masterKey = SymmetricKey(data: secret)
        let derivationContext = Data("cmux.socket-capability.v1\0\(audience)".utf8)
        let derivedKey = HMAC<SHA256>.authenticationCode(
            for: derivationContext,
            using: masterKey
        )
        signingKey = SymmetricKey(data: derivedKey)
    }

    /// Issues a capability with a cryptographically secure random nonce.
    ///
    /// - Returns: An opaque URL-safe token suitable for an environment value.
    public func issueCapability() -> String {
        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0..<Self.secureByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
        return issueCapability(nonce: nonce)
    }

    /// Issues a capability from an explicit nonce.
    ///
    /// This initializer-shaped seam makes signing deterministic in tests;
    /// production callers should use ``issueCapability()``.
    ///
    /// - Parameter nonce: Unique 32-byte nonce.
    /// - Returns: An opaque URL-safe token, or an empty string for invalid input.
    func issueCapability(nonce: Data) -> String {
        guard nonce.count == Self.secureByteCount else { return "" }
        let signature = HMAC<SHA256>.authenticationCode(
            for: authenticationMessage(nonce: nonce),
            using: signingKey
        )
        return "v1.\(base64URLEncoded(nonce)).\(base64URLEncoded(Data(signature)))"
    }

    /// Verifies that a capability was issued by this audience-scoped authority.
    ///
    /// - Parameter capability: Opaque token presented by a socket client.
    /// - Returns: `true` only for a structurally valid token with a valid MAC.
    public func verifies(_ capability: String) -> Bool {
        let components = capability.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "v1",
              let nonce = base64URLDecoded(String(components[1])),
              nonce.count == Self.secureByteCount,
              let signature = base64URLDecoded(String(components[2])),
              signature.count == SHA256.byteCount else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature,
            authenticating: authenticationMessage(nonce: nonce),
            using: signingKey
        )
    }

    private func authenticationMessage(nonce: Data) -> Data {
        Data("cmux.socket-capability.token.v1\0".utf8) + nonce
    }

    private func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func base64URLDecoded(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else {
            return nil
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }
}
