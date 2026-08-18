/// Backend-signed seven-day permission for one iOS initiator and Mac acceptor.
public struct PeerPairGrantResponse: Codable, Equatable, Sendable {
    public let grant: String
    public let expiresAt: String

    private enum CodingKeys: String, CodingKey {
        case grant
        case expiresAt = "expires_at"
    }

    public init(grant: String, expiresAt: String) {
        self.grant = grant
        self.expiresAt = expiresAt
    }
}

/// Backend-signed endpoint/account proof cached for offline same-account pairing.
public struct PeerEndpointAttestationResponse: Codable, Equatable, Sendable {
    public let attestationVersion: Int
    public let attestation: String
    public let expiresAt: String
    public let grantVerificationKeys: PeerGrantVerificationKeySet

    private enum CodingKeys: String, CodingKey {
        case attestationVersion = "attestation_version"
        case attestation
        case expiresAt = "expires_at"
        case grantVerificationKeys = "grant_verification_keys"
    }
}

/// The caller intent recorded on a binding revocation.
///
/// The wire bodies are unchanged: `own` omits the intent field, the others
/// send the previous transport's exact intent strings.
public enum PeerBindingRevocationIntent: String, Equatable, Sendable {
    /// Revoke the caller's own binding.
    case own
    /// Clean up an older binding owned by this app namespace and device.
    case stale = "revoke_stale"
    /// Forget one same-build Mac through explicit account management.
    case forgetMac = "forget_mac"
}

/// DELETE `api/devices/iroh` request body.
struct PeerBrokerRevokeRequest: Encodable {
    let bindingId: String
    let intent: String?

    private enum CodingKeys: String, CodingKey {
        case bindingId
        case intent
    }

    init(bindingID: String, intent: PeerBindingRevocationIntent) {
        bindingId = bindingID
        self.intent = intent == .own ? nil : intent.rawValue
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bindingId, forKey: .bindingId)
        try container.encodeIfPresent(intent, forKey: .intent)
    }
}

/// DELETE `api/devices/iroh` response body.
struct PeerBrokerRevokeResponse: Decodable, Sendable {
    let revoked: Bool
    let lanRendezvousRotated: Bool

    private enum CodingKeys: String, CodingKey {
        case revoked
        case lanRendezvousRotated = "lan_rendezvous_rotated"
    }
}
