/// Revisioned authoritative route reconciliation used by connectivity v2.
public protocol CmxConnectivityAuthorityServing: Sendable {
    /// Reconciles the caller's last installed revision with the backend.
    ///
    /// - Parameter knownRevision: The last completely installed snapshot, or
    ///   `nil` when no authoritative snapshot is available.
    /// - Returns: An unchanged acknowledgement or one complete replacement snapshot.
    nonisolated func syncConnectivity(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse
}

extension CmxIrohTrustBrokerClient: CmxConnectivityAuthorityServing {}

/// Single fail-closed owner of authoritative discovery revision semantics.
struct CmxAuthoritativeDiscoveryResolver: Sendable {
    private let broker: any CmxIrohDiscoveryServing

    init(broker: any CmxIrohDiscoveryServing) {
        self.broker = broker
    }

    func resolve(
        cached: CmxIrohDiscoveryResponse?,
        minimumRevision: UInt64? = nil
    ) async throws -> CmxIrohDiscoveryResponse {
        guard let authority = broker as? any CmxConnectivityAuthorityServing else {
            let discovery = try await broker.discover()
            try Self.requireRevision(
                discovery,
                atLeast: minimumRevision ?? cached?.revision
            )
            return discovery
        }
        let response = try await authority.syncConnectivity(
            knownRevision: cached?.revision
        )
        if let snapshot = response.snapshot,
           response.snapshotIsComplete {
            try Self.requireRevision(snapshot, atLeast: minimumRevision)
            if !response.reset {
                try Self.requireRevision(snapshot, atLeast: cached?.revision)
            }
            return snapshot
        }
        if response.snapshot != nil {
            let discovery = try await broker.discover()
            try Self.requireRevision(discovery, atLeast: response.revision)
            try Self.requireRevision(discovery, atLeast: minimumRevision)
            if !response.reset {
                try Self.requireRevision(discovery, atLeast: cached?.revision)
            }
            return discovery
        }
        guard !response.reset,
              let cached,
              cached.revision == response.revision else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        try Self.requireRevision(cached, atLeast: minimumRevision)
        return cached
    }

    func sync(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse {
        if let authority = broker as? any CmxConnectivityAuthorityServing {
            return try await authority.syncConnectivity(
                knownRevision: knownRevision
            )
        }
        return CmxConnectivitySyncResponse(
            legacySnapshot: try await broker.discover(),
            knownRevision: knownRevision
        )
    }

    private static func requireRevision(
        _ discovery: CmxIrohDiscoveryResponse,
        atLeast minimumRevision: UInt64?
    ) throws {
        guard let minimumRevision else { return }
        guard let revision = discovery.revision,
              revision >= minimumRevision else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
    }
}
