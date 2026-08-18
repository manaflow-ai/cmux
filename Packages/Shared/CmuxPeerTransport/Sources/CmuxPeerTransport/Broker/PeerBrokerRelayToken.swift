import CMUXMobileCore
import Foundation

/// One endpoint-scoped credential for one exact managed relay origin.
public struct PeerBrokerRelayCredential: Codable, Equatable, Sendable {
    /// The canonical relay origin (`https://host/`).
    public let relayURL: String
    /// The endpoint-bound relay JWT.
    public let token: String
    /// The provider-enforced expiry in ISO 8601 format.
    public let expiresAt: String
    /// The replacement time in ISO 8601 format.
    public let refreshAfter: String

    private enum CodingKeys: String, CodingKey {
        case relayURL = "relay_url"
        case token
        case expiresAt = "expires_at"
        case refreshAfter = "refresh_after"
    }

    public init(relayURL: String, token: String, expiresAt: String, refreshAfter: String) {
        self.relayURL = relayURL
        self.token = token
        self.expiresAt = expiresAt
        self.refreshAfter = refreshAfter
    }
}

/// Endpoint-scoped credentials for one exact managed relay fleet.
///
/// Decodes the URL-keyed wire format or the legacy homogeneous-fleet format,
/// byte-for-byte compatible with the previous transport.
public struct PeerBrokerRelayTokenResponse: Codable, Equatable, Sendable {
    /// URL-keyed relay credentials returned by the broker.
    public let credentials: [PeerBrokerRelayCredential]

    /// The complete ordered managed relay fleet covered by the response.
    public var relayFleet: [String] {
        credentials.map(\.relayURL)
    }

    public init(credentials: [PeerBrokerRelayCredential]) {
        self.credentials = credentials
    }

    /// Expands one legacy fleet-wide token into the URL-keyed model.
    public init(
        token: String,
        expiresAt: String,
        refreshAfter: String,
        relayFleet: [String]
    ) {
        credentials = relayFleet.map {
            PeerBrokerRelayCredential(
                relayURL: $0,
                token: token,
                expiresAt: expiresAt,
                refreshAfter: refreshAfter
            )
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.credentials) {
            self.init(
                credentials: try container.decode(
                    [PeerBrokerRelayCredential].self,
                    forKey: .credentials
                )
            )
            return
        }
        self.init(
            token: try container.decode(String.self, forKey: .token),
            expiresAt: try container.decode(String.self, forKey: .expiresAt),
            refreshAfter: try container.decode(String.self, forKey: .refreshAfter),
            relayFleet: try container.decode([String].self, forKey: .relayFleet)
        )
    }

    /// Encodes only the URL-keyed format so newly persisted state is unambiguous.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(credentials, forKey: .credentials)
    }

    private enum CodingKeys: String, CodingKey {
        case credentials = "relay_credentials"
        case token
        case expiresAt = "expires_at"
        case refreshAfter = "refresh_after"
        case relayFleet = "relay_fleet"
    }
}

/// Internal decode/validation for `api/relay/token` responses.
///
/// This route uses camelCase keys, unlike the registration relay envelope.
struct PeerBrokerRelayAccessResponse: Decodable, Sendable {
    struct Credential: Decodable, Sendable {
        let relayUrl: String
        let token: String
        let expiresAt: Int64
        let refreshAfter: Int64
        let ttlSeconds: Int64
    }

    private struct TokenHeader: Decodable {
        let alg: String
        let typ: String
    }

    private struct TokenClaims: Decodable {
        let issuer: String
        let audience: String
        let expiresAt: Int64
        let endpointID: String

        private enum CodingKeys: String, CodingKey {
            case issuer = "iss"
            case audience = "aud"
            case expiresAt = "exp"
            case endpointID = "endpoint_id"
        }
    }

    let token: String?
    let expiresAt: Int64?
    let ttlSeconds: Int64?
    let relays: [String]?
    let endpointId: String?
    let relayCredentials: [Credential]?

    /// Validates and normalizes the response into fleet credentials.
    ///
    /// Rules are unchanged: endpoint binding, bounded fleet size, canonical
    /// deduplicated origins, TTL/refresh window sanity, and (legacy form) a
    /// structurally valid EdDSA JWT bound to this exact endpoint.
    func tokenResponse(
        endpointID: CmxIrohPeerIdentity
    ) throws -> PeerBrokerRelayTokenResponse {
        if let relayCredentials {
            guard endpointId == endpointID.endpointID,
                  (1 ... PeerBrokerWire.maximumRelayCount).contains(relayCredentials.count) else {
                throw PeerBrokerError.protocolError
            }
            let normalized = try relayCredentials.map { credential in
                guard (30 ... 24 * 60 * 60).contains(credential.ttlSeconds),
                      credential.expiresAt > credential.refreshAfter,
                      credential.refreshAfter
                          >= credential.expiresAt - credential.ttlSeconds,
                      (1 ... 8 * 1_024).contains(credential.token.utf8.count),
                      let origin = PeerBrokerWire.canonicalRelayOrigin(credential.relayUrl)
                else {
                    throw PeerBrokerError.protocolError
                }
                return PeerBrokerRelayCredential(
                    relayURL: origin,
                    token: credential.token,
                    expiresAt: PeerBrokerWire.iso8601(epochSeconds: credential.expiresAt),
                    refreshAfter: PeerBrokerWire.iso8601(epochSeconds: credential.refreshAfter)
                )
            }
            guard Set(normalized.map(\.relayURL)).count == normalized.count else {
                throw PeerBrokerError.protocolError
            }
            return PeerBrokerRelayTokenResponse(credentials: normalized)
        }

        guard let token,
              let expiresAtSeconds = expiresAt,
              let ttlSeconds,
              let relays,
              ttlSeconds == 300,
              expiresAtSeconds > ttlSeconds,
              (1 ... PeerBrokerWire.maximumRelayCount).contains(relays.count),
              Self.isValidRelayJWT(
                  token,
                  expiresAt: expiresAtSeconds,
                  endpointID: endpointID
              ) else {
            throw PeerBrokerError.protocolError
        }
        let relayFleet = try relays.map { relay in
            guard let origin = PeerBrokerWire.canonicalRelayOrigin(relay) else {
                throw PeerBrokerError.protocolError
            }
            return origin
        }
        guard Set(relayFleet).count == relayFleet.count else {
            throw PeerBrokerError.protocolError
        }
        let refreshLead = min(60, ttlSeconds / 2)
        return PeerBrokerRelayTokenResponse(
            token: token,
            expiresAt: PeerBrokerWire.iso8601(epochSeconds: expiresAtSeconds),
            refreshAfter: PeerBrokerWire.iso8601(epochSeconds: expiresAtSeconds - refreshLead),
            relayFleet: relayFleet
        )
    }

    private static func isValidRelayJWT(
        _ token: String,
        expiresAt: Int64,
        endpointID: CmxIrohPeerIdentity
    ) -> Bool {
        guard (1 ... 8 * 1_024).contains(token.utf8.count) else { return false }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let headerData = Self.lenientBase64URLData(segments[0]),
              let claimsData = Self.lenientBase64URLData(segments[1]),
              let header = try? JSONDecoder().decode(TokenHeader.self, from: headerData),
              let claims = try? JSONDecoder().decode(TokenClaims.self, from: claimsData) else {
            return false
        }
        return header.alg == "EdDSA"
            && header.typ == "JWT"
            && claims.issuer == "cmux"
            && claims.audience == "cmux-relay"
            && claims.expiresAt == expiresAt
            && claims.endpointID == endpointID.endpointID
    }

    /// Structural base64url decode used only for relay JWT inspection.
    /// (The relay verifies the signature; this check binds the claims.)
    private static func lenientBase64URLData(_ value: Substring) -> Data? {
        var encoded = String(value)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.utf8.count % 4
        if remainder != 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: encoded)
    }
}
