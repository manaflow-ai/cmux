public import Foundation

/// A short-lived endpoint-scoped credential for one managed relay.
public struct CmxIrohRelayConfiguration: Equatable, Sendable {
    /// The exact canonical relay URL accepted by the app configuration.
    public let url: String

    /// The lowercase unpadded Base32 RCAN token.
    public let token: String

    /// The hard time after which the relay must reject the token.
    public let expiresAt: Date

    /// The time at which cmux should obtain a replacement before expiry.
    public let refreshAfter: Date

    /// Creates a validated managed-relay configuration.
    ///
    /// - Parameters:
    ///   - url: A canonical HTTPS relay origin with a trailing slash.
    ///   - token: A lowercase unpadded Base32 RCAN token.
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
        let tokenBytes = Array(token.utf8)
        guard (1 ... 8 * 1_024).contains(tokenBytes.count),
              tokenBytes.allSatisfy({
                  (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains($0)
                      || (UInt8(ascii: "2") ... UInt8(ascii: "7")).contains($0)
              })
        else {
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
