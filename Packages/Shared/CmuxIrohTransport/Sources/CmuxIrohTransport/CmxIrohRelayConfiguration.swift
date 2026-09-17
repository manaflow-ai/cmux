public import Foundation

/// A short-lived endpoint-scoped credential for one managed relay.
public struct CmxIrohRelayConfiguration: Equatable, Sendable {
    /// The exact canonical relay URL accepted by the app configuration.
    public let url: String

    /// The compact JWT, or pre-migration RCAN, used as Iroh's relay auth token.
    public let token: String

    /// The hard time after which the relay must reject the token.
    public let expiresAt: Date

    /// The time at which cmux should obtain a replacement before expiry.
    public let refreshAfter: Date

    /// Creates a validated managed-relay configuration.
    ///
    /// - Parameters:
    ///   - url: A canonical HTTPS relay origin with a trailing slash.
    ///   - token: A compact Base64URL JWT or legacy lowercase Base32 RCAN.
    ///   - expiresAt: The provider-enforced token expiry.
    ///   - refreshAfter: A replacement time strictly before expiry.
    ///   - now: The validation time, injected for deterministic tests.
    /// - Throws: ``CmxIrohRelayConfigurationError`` for malformed or expired input.
    public init(
        url: String,
        token: String,
        expiresAt: Date,
        refreshAfter: Date,
        now: Date
    ) throws {
        guard Self.isCanonicalRelayURL(url) else {
            throw CmxIrohRelayConfigurationError.invalidURL
        }
        guard (1 ... 8 * 1_024).contains(token.utf8.count),
              Self.isCompactJWT(token) || Self.isLegacyRCAN(token) else {
            throw CmxIrohRelayConfigurationError.invalidToken
        }
        guard now < refreshAfter, refreshAfter < expiresAt else {
            throw CmxIrohRelayConfigurationError.invalidLifetime
        }
        self.url = url
        self.token = token
        self.expiresAt = expiresAt
        self.refreshAfter = refreshAfter
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
            || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
            || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "_")
    }

    private static func isCompactJWT(_ value: String) -> Bool {
        let segments = value.split(separator: ".", omittingEmptySubsequences: false)
        return segments.count == 3 && segments.allSatisfy { segment in
            !segment.isEmpty && segment.utf8.allSatisfy(Self.isBase64URLByte)
        }
    }

    private static func isLegacyRCAN(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "2") ... UInt8(ascii: "7")).contains(byte)
        }
    }

    private static func isCanonicalRelayURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme == "https",
              let host = components.host,
              host == host.lowercased(),
              !host.isEmpty,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path == "/" else {
            return false
        }
        return components.string == value
    }
}
