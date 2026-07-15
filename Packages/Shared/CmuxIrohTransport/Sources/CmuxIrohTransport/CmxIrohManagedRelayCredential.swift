/// One broker-issued credential associated with one exact managed relay URL.
public struct CmxIrohManagedRelayCredential: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// The exact canonical relay URL covered by this credential.
    public let relayURL: String

    /// The opaque relay authentication token.
    public let token: String

    /// The provider-enforced expiry in ISO 8601 format.
    public let expiresAt: String

    /// The replacement time in ISO 8601 format.
    public let refreshAfter: String

    /// Creates one URL-bound managed relay credential.
    ///
    /// Structural and lifetime validation is centralized in
    /// ``CmxIrohRelayTokenResponse/relayConfigurations(now:)`` so network and
    /// restored credentials follow the same validation path.
    ///
    /// - Parameters:
    ///   - relayURL: The exact managed relay URL covered by the token.
    ///   - token: The provider-issued opaque relay token.
    ///   - expiresAt: The provider-enforced expiry in ISO 8601 format.
    ///   - refreshAfter: The replacement time in ISO 8601 format.
    public init(
        relayURL: String,
        token: String,
        expiresAt: String,
        refreshAfter: String
    ) {
        self.relayURL = relayURL
        self.token = token
        self.expiresAt = expiresAt
        self.refreshAfter = refreshAfter
    }

    /// A log-safe representation that never includes the opaque token.
    public var description: String {
        "CmxIrohManagedRelayCredential(relayURL: \(relayURL), token: <redacted>, "
            + "expiresAt: \(expiresAt), refreshAfter: \(refreshAfter))"
    }

    /// A debug representation that never includes the opaque token.
    public var debugDescription: String { description }

    private enum CodingKeys: String, CodingKey {
        case relayURL = "relay_url"
        case token
        case expiresAt = "expires_at"
        case refreshAfter = "refresh_after"
    }
}
