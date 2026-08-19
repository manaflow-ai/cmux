public import Foundation

/// One broker-issued credential associated with one exact managed relay URL.
public struct PeerRelayCredential: Codable, Equatable, Sendable,
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
    /// ``PeerRelayTokenResponse/relayConfigs(now:)`` so network and restored
    /// credentials follow the same validation path.
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
        "PeerRelayCredential(relayURL: \(relayURL), token: <redacted>, "
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

/// Endpoint-scoped credentials for one exact managed relay fleet.
///
/// Wire-compatible with the legacy broker response: the URL-keyed
/// `relay_credentials` format is canonical, and the legacy homogeneous-fleet
/// format (`token` + `expires_at` + `refresh_after` + `relay_fleet`) still
/// decodes so cached responses and older brokers keep working.
public struct PeerRelayTokenResponse: Codable, Equatable, Sendable {
    /// URL-keyed relay credentials returned by the broker.
    public let credentials: [PeerRelayCredential]

    /// The complete ordered managed relay fleet covered by the response.
    public var relayFleet: [String] {
        credentials.map(\.relayURL)
    }

    /// Creates a response containing independently issued relay credentials.
    ///
    /// - Parameter credentials: One credential for every signed managed relay.
    public init(credentials: [PeerRelayCredential]) {
        self.credentials = credentials
    }

    /// Creates a legacy homogeneous-fleet response for cache and API migration.
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
            PeerRelayCredential(
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
                    [PeerRelayCredential].self,
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
    /// - Throws: A coarse invalid-credential error for malformed, stale,
    ///   duplicate, or over-sized credential sets.
    public func relayConfigs(now: Date) throws -> [PeerRelayConfig] {
        guard (1 ... PeerRelayPolicyVerifier.maximumRelayCount).contains(
            credentials.count
        ),
        Set(credentials.map(\.relayURL)).count == credentials.count else {
            throw PeerRelayCredentialPlanError.invalidCredential
        }
        do {
            return try credentials.map { credential in
                guard let expiresAt = PeerRelayWireDate.parse(credential.expiresAt),
                      let refreshAfter = PeerRelayWireDate.parse(credential.refreshAfter)
                else {
                    throw PeerRelayCredentialPlanError.invalidCredential
                }
                return try PeerRelayConfig(
                    url: credential.relayURL,
                    authToken: credential.token,
                    expiresAt: expiresAt,
                    refreshAfter: refreshAfter,
                    now: now
                )
            }
        } catch {
            throw PeerRelayCredentialPlanError.invalidCredential
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

/// Broker dates are ISO 8601 with or without fractional seconds.
enum PeerRelayWireDate {
    static func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
