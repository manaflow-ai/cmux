public import Foundation

/// Endpoint-scoped credentials for one exact managed relay fleet.
public struct CmxIrohRelayTokenResponse: Codable, Equatable, Sendable {
    /// URL-keyed relay credentials returned by the broker.
    public let credentials: [CmxIrohManagedRelayCredential]

    /// The complete ordered managed relay fleet covered by the response.
    public var relayFleet: [String] {
        credentials.map(\.relayURL)
    }

    /// Creates a response containing independently issued relay credentials.
    ///
    /// - Parameter credentials: One credential for every signed managed relay.
    public init(credentials: [CmxIrohManagedRelayCredential]) {
        self.credentials = credentials
    }

    /// Creates a legacy homogeneous-fleet response for cache and API migration.
    ///
    /// New broker responses should use ``init(credentials:)``. This initializer
    /// remains so a single legacy token can be expanded into the URL-keyed model.
    ///
    /// - Parameters:
    ///   - token: One token accepted by every relay in `relayFleet`.
    ///   - expiresAt: The shared provider-enforced expiry in ISO 8601 format.
    ///   - refreshAfter: The shared replacement time in ISO 8601 format.
    ///   - relayFleet: The complete managed relay fleet covered by the token.
    public init(
        token: String,
        expiresAt: String,
        refreshAfter: String,
        relayFleet: [String]
    ) {
        credentials = relayFleet.map {
            CmxIrohManagedRelayCredential(
                relayURL: $0,
                token: token,
                expiresAt: expiresAt,
                refreshAfter: refreshAfter
            )
        }
    }

    /// Decodes the URL-keyed wire format or the legacy homogeneous-fleet format.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.credentials) {
            self.init(
                credentials: try container.decode(
                    [CmxIrohManagedRelayCredential].self,
                    forKey: .credentials
                )
            )
            return
        }
        let token = try container.decode(String.self, forKey: .token)
        let expiresAt = try container.decode(String.self, forKey: .expiresAt)
        let refreshAfter = try container.decode(String.self, forKey: .refreshAfter)
        let relayFleet = try container.decode([String].self, forKey: .relayFleet)
        self.init(
            token: token,
            expiresAt: expiresAt,
            refreshAfter: refreshAfter,
            relayFleet: relayFleet
        )
    }

    /// Encodes only the URL-keyed format so newly persisted state is unambiguous.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(credentials, forKey: .credentials)
    }

    /// Validates every URL-token association and creates endpoint credentials.
    ///
    /// - Parameter now: The validation time.
    /// - Returns: One configuration for every unique relay URL.
    /// - Throws: A coarse invalid-response error for malformed, stale, duplicate,
    ///   or over-sized credential sets.
    public func relayConfigurations(now: Date) throws -> [CmxIrohRelayConfiguration] {
        guard (1 ... CmxIrohRelayPolicyVerifier.maximumRelayCount).contains(
            credentials.count
        ),
        Set(credentials.map(\.relayURL)).count == credentials.count else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        do {
            return try credentials.map { credential in
                guard let expiresAt = CmxIrohISO8601Date.parse(credential.expiresAt),
                      let refreshAfter = CmxIrohISO8601Date.parse(credential.refreshAfter) else {
                    throw CmxIrohTrustBrokerClientError.invalidResponse
                }
                return try CmxIrohRelayConfiguration(
                    url: credential.relayURL,
                    token: credential.token,
                    expiresAt: expiresAt,
                    refreshAfter: refreshAfter,
                    now: now
                )
            }
        } catch {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
    }

    private enum CodingKeys: String, CodingKey {
        case credentials = "relay_credentials"
        case token
        case expiresAt = "expires_at"
        case refreshAfter = "refresh_after"
        case relayFleet = "relay_fleet"
    }
}
