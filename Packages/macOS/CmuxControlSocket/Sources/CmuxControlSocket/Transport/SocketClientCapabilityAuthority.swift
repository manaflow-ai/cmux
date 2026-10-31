internal import CryptoKit
public import Foundation

/// Issues and verifies opaque bearer capabilities for cmux-created terminals.
///
/// An authority is immutable and contains no session registry. Tokens issued
/// from the same secret and audience remain valid across listener and app
/// restarts, while a different app variant derives an independent signing key.
// CryptoKit only declared `SymmetricKey` as `Sendable` in newer SDKs. The key
// is an immutable value and this authority never exposes or mutates it, so the
// same concurrency contract is safe when compiling with Xcode 16.2.
public struct SocketClientCapabilityAuthority: @unchecked Sendable {
    /// Required byte count for master secrets and per-token nonces.
    public static let secureByteCount = 32

    /// Detached hook monitors are bounded by the four-hour Codex monitor
    /// deadline. Their capability expires shortly after that deadline so a
    /// stale monitor cannot retain socket access indefinitely.
    public static let deliveryCapabilityLifetime: TimeInterval =
        (4 * 60 * 60) + (5 * 60)

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
    public func issueCapability(nonce: Data) -> String {
        guard nonce.count == Self.secureByteCount else { return "" }
        let signature = HMAC<SHA256>.authenticationCode(
            for: authenticationMessage(nonce: nonce),
            using: signingKey
        )
        return "v1.\(base64URLEncoded(nonce)).\(base64URLEncoded(Data(signature)))"
    }

    /// Issues a capability for an app-owned detached hook delivery.
    ///
    /// Unlike inherited terminal capabilities, delivery capabilities carry a
    /// signed expiry. They are intentionally kept out of the durable event
    /// and spool state; the app creates one immediately before launching the
    /// delivery process.
    public func issueDeliveryCapability(
        nonce: Data,
        expiresAt: Date
    ) -> String {
        guard nonce.count == Self.secureByteCount,
              let expiry = Self.expirySeconds(expiresAt) else {
            return ""
        }
        let signature = HMAC<SHA256>.authenticationCode(
            for: deliveryAuthenticationMessage(expiry: expiry, nonce: nonce),
            using: signingKey
        )
        return "v2.\(expiry).\(base64URLEncoded(nonce)).\(base64URLEncoded(Data(signature)))"
    }

    /// Issues a short-lived delivery capability using the current wall clock.
    public func issueDeliveryCapability(
        expiresIn lifetime: TimeInterval = Self.deliveryCapabilityLifetime
    ) -> String {
        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0..<Self.secureByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
        return issueDeliveryCapability(
            nonce: nonce,
            expiresAt: Date().addingTimeInterval(lifetime)
        )
    }

    /// Verifies that a capability was issued by this audience-scoped authority.
    ///
    /// - Parameters:
    ///   - capability: Opaque token presented by a socket client.
    ///   - now: Clock used for expiring delivery capabilities. The default is
    ///     the current wall clock; the parameter is injectable for tests.
    /// - Returns: `true` only for a structurally valid token with a valid MAC.
    public func verifies(_ capability: String, now: Date = Date()) -> Bool {
        let components = capability.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 || components.count == 4 else {
            return false
        }
        if components[0] == "v1" {
            guard components.count == 3,
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
        guard components[0] == "v2",
              components.count == 4,
              let expiry = UInt64(components[1]),
              String(expiry) == String(components[1]),
              now.timeIntervalSince1970 < TimeInterval(expiry),
              let nonce = base64URLDecoded(String(components[2])),
              nonce.count == Self.secureByteCount,
              let signature = base64URLDecoded(String(components[3])),
              signature.count == SHA256.byteCount else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(
            signature,
            authenticating: deliveryAuthenticationMessage(expiry: expiry, nonce: nonce),
            using: signingKey
        )
    }

    private func authenticationMessage(nonce: Data) -> Data {
        Data("cmux.socket-capability.token.v1\0".utf8) + nonce
    }

    private func deliveryAuthenticationMessage(expiry: UInt64, nonce: Data) -> Data {
        Data("cmux.socket-capability.delivery.v2\0\(expiry)\0".utf8) + nonce
    }

    private static func expirySeconds(_ date: Date) -> UInt64? {
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite, timestamp > 0,
              timestamp < TimeInterval(UInt64.max) else {
            return nil
        }
        return UInt64(timestamp.rounded(.down))
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
