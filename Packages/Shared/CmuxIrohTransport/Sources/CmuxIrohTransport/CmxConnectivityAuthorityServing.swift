/// Revisioned authoritative route reconciliation used by connectivity v2.
public protocol CmxConnectivityAuthorityServing: Sendable {
    /// Reconciles the caller's last installed revision with the backend.
    ///
    /// - Parameter knownRevision: The last completely installed snapshot, or
    ///   `nil` when no authoritative snapshot is available.
    /// - Returns: An unchanged acknowledgement or one complete replacement snapshot.
    func syncConnectivity(
        knownRevision: UInt64?
    ) async throws -> CmxConnectivitySyncResponse
}

extension CmxIrohTrustBrokerClient: CmxConnectivityAuthorityServing {}

/// Single fail-closed owner of authoritative discovery revision semantics.
enum CmxAuthoritativeDiscoveryResolver {
    static func resolve(
        broker: any CmxIrohDiscoveryServing,
        cached: CmxIrohDiscoveryResponse?
    ) async throws -> CmxIrohDiscoveryResponse {
        guard let authority = broker as? any CmxConnectivityAuthorityServing else {
            return try await broker.discover()
        }
        let response = try await authority.syncConnectivity(
            knownRevision: cached?.revision
        )
        if let snapshot = response.snapshot {
            return snapshot
        }
        guard let cached, cached.revision == response.revision else {
            throw CmxIrohTrustBrokerClientError.invalidResponse
        }
        return cached
    }

    static func sync(
        broker: any CmxIrohDiscoveryServing,
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
}
