/// POST body for the connectivity reconciliation routes.
struct PeerConnectivitySyncRequest: Encodable {
    let protocolVersion: Int
    let knownRevision: UInt64?
    let discoveryScope: PeerDiscoveryScope?

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case knownRevision = "known_revision"
        case discoveryScope = "discovery_scope"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        if let knownRevision {
            try container.encode(knownRevision, forKey: .knownRevision)
        } else {
            // The wire contract distinguishes an initial sync (`null`) from an
            // absent field. Swift's synthesized Optional encoding omits nil
            // values, which the bounded server parser rejects as incomplete.
            try container.encodeNil(forKey: .knownRevision)
        }
        try container.encodeIfPresent(discoveryScope, forKey: .discoveryScope)
    }
}

/// Versioned response from the authoritative connectivity reconciliation route.
public struct PeerConnectivitySyncResponse: Decodable, Equatable, Sendable {
    /// The global-snapshot protocol used when scoped discovery is unavailable.
    public static let protocolVersion = 2
    /// The bounded discovery protocol used by current clients.
    public static let scopedProtocolVersion = 3

    /// Backend connectivity protocol version.
    public let protocolVersion: Int
    /// Current monotonic account route revision.
    public let revision: UInt64
    /// Whether the caller must install a replacement snapshot.
    public let changed: Bool
    /// Whether the caller was ahead of the backend and must discard history.
    public let reset: Bool
    /// Complete authoritative discovery state when `changed` is true.
    public let snapshot: PeerBrokerDiscoverySnapshot?
    /// True only when the server proves `snapshot` covers every active binding.
    public let snapshotComplete: Bool?
    /// The bounded projection represented by a connectivity v3 snapshot.
    public let discoveryScope: PeerDiscoveryScope?
    /// True only when the server proves `snapshot` covers the echoed scope.
    public let snapshotScopeComplete: Bool?

    /// Whether the snapshot carries either global or scoped completeness proof.
    public var snapshotIsComplete: Bool {
        snapshot != nil
            && (snapshotComplete == true || snapshotScopeComplete == true)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case revision
        case changed
        case reset
        case snapshot
        case snapshotComplete = "snapshot_complete"
        case discoveryScope = "discovery_scope"
        case snapshotScopeComplete = "snapshot_scope_complete"
    }

    /// Decodes and validates one atomic reconciliation response.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        let revision = try container.decode(UInt64.self, forKey: .revision)
        let changed = try container.decode(Bool.self, forKey: .changed)
        let reset = try container.decode(Bool.self, forKey: .reset)
        let snapshot = try container.decodeIfPresent(
            PeerBrokerDiscoverySnapshot.self,
            forKey: .snapshot
        )
        let snapshotComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .snapshotComplete
        )
        let discoveryScope = try container.decodeIfPresent(
            PeerDiscoveryScope.self,
            forKey: .discoveryScope
        )
        let snapshotScopeComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .snapshotScopeComplete
        )
        let validCompletenessContract = switch protocolVersion {
        case Self.protocolVersion:
            discoveryScope == nil && snapshotScopeComplete == nil
        case Self.scopedProtocolVersion:
            discoveryScope != nil && snapshotComplete == nil
        default:
            false
        }
        guard validCompletenessContract,
              changed == (snapshot != nil),
              !reset || changed,
              snapshot != nil || snapshotComplete == nil,
              snapshot != nil || snapshotScopeComplete == nil,
              (snapshot?.routeContractVersion ?? 1) == 1,
              (snapshot?.revision ?? revision) == revision else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid connectivity sync response"
                )
            )
        }
        self.protocolVersion = protocolVersion
        self.revision = revision
        self.changed = changed
        self.reset = reset
        self.snapshot = snapshot
        self.snapshotComplete = snapshotComplete
        self.discoveryScope = discoveryScope
        self.snapshotScopeComplete = snapshotScopeComplete
    }
}
