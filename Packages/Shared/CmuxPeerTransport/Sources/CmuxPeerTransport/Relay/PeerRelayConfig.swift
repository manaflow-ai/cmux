public import Foundation

/// Validation failures for one endpoint-scoped relay credential.
public enum PeerRelayConfigError: Error, Equatable, Sendable {
    /// The relay URL is not a canonical HTTPS origin.
    case invalidURL

    /// The auth token is empty, oversized, or not a JWT/RCAN shape.
    case invalidToken

    /// The token lifetime is not `now < refreshAfter < expiresAt`.
    case invalidLifetime
}

/// A short-lived endpoint-scoped credential for one managed relay.
///
/// This is the value the endpoint executor turns into an IrohLib
/// `RelayConfig(url:authToken:)`; the auth token rides the relay websocket
/// upgrade as `Authorization: Bearer`.
public struct PeerRelayConfig: Equatable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// The exact canonical relay URL accepted by the app configuration.
    public let url: String

    /// The compact JWT, or pre-migration RCAN, used as the relay auth token.
    public let authToken: String

    /// The hard time after which the relay must reject the token.
    public let expiresAt: Date

    /// The time at which cmux should obtain a replacement before expiry.
    public let refreshAfter: Date

    /// Creates a validated managed-relay configuration.
    ///
    /// - Parameters:
    ///   - url: A canonical HTTPS relay origin with a trailing slash.
    ///   - authToken: A compact Base64URL JWT or legacy lowercase Base32 RCAN.
    ///   - expiresAt: The provider-enforced token expiry.
    ///   - refreshAfter: A replacement time strictly before expiry.
    ///   - now: The validation time, injected for deterministic tests.
    /// - Throws: ``PeerRelayConfigError`` for malformed or expired input.
    public init(
        url: String,
        authToken: String,
        expiresAt: Date,
        refreshAfter: Date,
        now: Date
    ) throws {
        guard Self.isCanonicalRelayURL(url) else {
            throw PeerRelayConfigError.invalidURL
        }
        guard (1 ... 8 * 1_024).contains(authToken.utf8.count),
              Self.isCompactJWT(authToken) || Self.isLegacyRCAN(authToken) else {
            throw PeerRelayConfigError.invalidToken
        }
        guard now < refreshAfter, refreshAfter < expiresAt else {
            throw PeerRelayConfigError.invalidLifetime
        }
        self.url = url
        self.authToken = authToken
        self.expiresAt = expiresAt
        self.refreshAfter = refreshAfter
    }

    /// A log-safe representation that never includes the auth token.
    public var description: String {
        "PeerRelayConfig(url: \(url), authToken: <redacted>, "
            + "expiresAt: \(expiresAt), refreshAfter: \(refreshAfter))"
    }

    /// A debug representation that never includes the auth token.
    public var debugDescription: String { description }

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
