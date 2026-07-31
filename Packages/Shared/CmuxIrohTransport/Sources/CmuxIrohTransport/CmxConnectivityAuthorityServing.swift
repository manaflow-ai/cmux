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
