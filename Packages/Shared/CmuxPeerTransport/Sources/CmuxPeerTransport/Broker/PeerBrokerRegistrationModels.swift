/// First registration leg that binds a broker nonce to exact endpoint state.
public struct PeerBrokerChallengeRequest: Encodable, Equatable, Sendable {
    public let deviceId: String
    public let appInstanceId: String
    public let clientNamespace: String
    public let tag: String
    public let endpointId: String
    public let identityGeneration: Int
    /// SHA-256 of the exact base64url-decoded payload bytes.
    public let payloadSha256: String

    init(payload: PeerRegistrationPayload, payloadSHA256: String) {
        deviceId = payload.deviceID
        appInstanceId = payload.appInstanceID
        clientNamespace = payload.clientNamespace
        tag = payload.tag
        endpointId = payload.endpointID
        identityGeneration = payload.identityGeneration
        payloadSha256 = payloadSHA256
    }
}

/// Broker-issued nonce used for one endpoint registration attempt.
public struct PeerBrokerChallengeResponse: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case nonce
        case expiresAt = "expires_at"
    }

    /// One-use broker challenge UUID.
    public let challengeID: String
    /// Canonical base64url encoding of 32 random bytes.
    public let nonce: String
    /// Broker expiry supplied for scheduling and diagnostics.
    public let expiresAt: String

    public init(challengeID: String, nonce: String, expiresAt: String) {
        self.challengeID = challengeID
        self.nonce = nonce
        self.expiresAt = expiresAt
    }
}

/// Signed second leg of endpoint registration.
public struct PeerBrokerRegisterRequest: Encodable, Equatable, Sendable {
    /// One-use challenge UUID.
    public let challengeId: String
    /// Broker nonce copied verbatim from the challenge.
    public let nonce: String
    /// Base64url-encoded canonical payload bytes.
    public let payload: String
    /// Base64url Ed25519 signature over the registration transcript.
    public let signature: String
    /// Optional bounded discovery projection returned with registration.
    public let discoveryScope: PeerDiscoveryScope?

    init(
        challengeID: String,
        nonce: String,
        payload: String,
        signature: String,
        discoveryScope: PeerDiscoveryScope? = nil
    ) {
        challengeId = challengeID
        self.nonce = nonce
        self.payload = payload
        self.signature = signature
        self.discoveryScope = discoveryScope
    }

    func including(discoveryScope: PeerDiscoveryScope?) -> Self {
        Self(
            challengeID: challengeId,
            nonce: nonce,
            payload: payload,
            signature: signature,
            discoveryScope: discoveryScope
        )
    }
}

/// Canonical registration bytes retained across the challenge round trip.
public struct PeerPreparedRegistration: Equatable, Sendable {
    /// Request body for `api/devices/iroh/challenge`.
    public let challengeRequest: PeerBrokerChallengeRequest
    /// Base64url-encoded registration payload.
    public let encodedPayload: String
    /// SHA-256 of the decoded payload bytes.
    public let payloadSHA256: String
    /// Exact endpoint identity declared by the payload.
    public let endpointID: String
}

/// Result of the registration route's best-effort initial relay mint.
public enum PeerBrokerRegistrationRelay: Decodable, Equatable, Sendable {
    case issued(PeerBrokerRelayTokenResponse)
    case unavailable
    case notRequested

    private enum CodingKeys: String, CodingKey { case status }

    public init(from decoder: any Decoder) throws {
        let status = try decoder.container(keyedBy: CodingKeys.self)
            .decode(String.self, forKey: .status)
        switch status {
        case "issued":
            self = try .issued(PeerBrokerRelayTokenResponse(from: decoder))
        case "unavailable":
            self = .unavailable
        case "not_requested":
            self = .notRequested
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown relay status")
            )
        }
    }
}

/// Registration response. Relay bootstrap failure never rolls back the binding.
public struct PeerBrokerRegistrationResponse: Decodable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case revision
        case binding
        case relay
        case discovery
        case discoveryComplete = "discovery_complete"
        case discoveryScope = "discovery_scope"
        case discoveryScopeComplete = "discovery_scope_complete"
    }

    /// Monotonic account route revision after this registration commit.
    public let revision: UInt64?
    public let binding: PeerBrokerBinding
    public let relay: PeerBrokerRegistrationRelay
    /// The authoritative post-registration account snapshot when supplied.
    public let discovery: PeerBrokerDiscoverySnapshot?
    /// True only when the embedded snapshot covers every active binding.
    public let discoveryComplete: Bool?
    /// The exact bounded projection represented by embedded discovery.
    public let discoveryScope: PeerDiscoveryScope?
    /// True only when embedded discovery covers every binding in its scope.
    public let discoveryScopeComplete: Bool?

    /// Whether the embedded discovery is proven complete globally or for its
    /// validated scoped-registration request.
    public var embeddedDiscoveryComplete: Bool {
        discovery != nil
            && (discoveryComplete == true
                || (discoveryScope != nil && discoveryScopeComplete == true))
    }
}
