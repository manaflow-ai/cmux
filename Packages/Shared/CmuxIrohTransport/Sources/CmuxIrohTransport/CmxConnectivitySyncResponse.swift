/// Versioned response from the authoritative connectivity reconciliation route.
public struct CmxConnectivitySyncResponse: Decodable, Equatable, Sendable {
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

    /// Whether the caller was ahead of the backend and must discard local history.
    public let reset: Bool

    /// Complete authoritative discovery state when `changed` is true.
    public let snapshot: CmxIrohDiscoveryResponse?

    /// True only when the server proves `snapshot` covers every active binding.
    /// Older servers omit this field, so clients fetch paginated discovery.
    public let snapshotComplete: Bool?

    /// The bounded projection represented by a connectivity v3 snapshot.
    public let discoveryScope: CmxConnectivityDiscoveryScope?

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
            CmxIrohDiscoveryResponse.self,
            forKey: .snapshot
        )
        let snapshotComplete = try container.decodeIfPresent(
            Bool.self,
            forKey: .snapshotComplete
        )
        let discoveryScope = try container.decodeIfPresent(
            CmxConnectivityDiscoveryScope.self,
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

    init(
        legacySnapshot: CmxIrohDiscoveryResponse,
        knownRevision: UInt64?,
        snapshotComplete: Bool? = true
    ) {
        protocolVersion = Self.protocolVersion
        revision = legacySnapshot.revision ?? (knownRevision ?? 0) &+ 1
        changed = true
        reset = false
        snapshot = legacySnapshot
        self.snapshotComplete = snapshotComplete
        discoveryScope = nil
        snapshotScopeComplete = nil
    }
}
