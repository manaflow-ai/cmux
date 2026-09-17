/// Versioned response from the authoritative connectivity reconciliation route.
public struct CmxConnectivitySyncResponse: Decodable, Equatable, Sendable {
    /// The only protocol version accepted by this implementation.
    public static let protocolVersion = 2

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

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case revision
        case changed
        case reset
        case snapshot
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
        guard protocolVersion == Self.protocolVersion,
              changed == (snapshot != nil),
              !reset || changed,
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
    }

    init(
        legacySnapshot: CmxIrohDiscoveryResponse,
        knownRevision: UInt64?
    ) {
        protocolVersion = Self.protocolVersion
        revision = legacySnapshot.revision ?? (knownRevision ?? 0) &+ 1
        changed = true
        reset = false
        snapshot = legacySnapshot
    }
}
