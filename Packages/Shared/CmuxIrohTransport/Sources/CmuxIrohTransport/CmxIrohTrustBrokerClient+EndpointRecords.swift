public import Foundation

/// Adapts the authenticated trust-broker client to the record broker the
/// address lookup consumes. Fetch rides the discovery snapshot (and its
/// backpressure gate); publish requires the retained binding authorization,
/// so a pre-registration publish fails typed instead of dialing unauthenticated.
extension CmxIrohTrustBrokerClient: CmxIrohEndpointRecordBroker {
    /// Fetches every stored endpoint record from the discovery snapshot.
    public func fetchEndpointRecords() async throws -> [Data] {
        try await discover().bindings.compactMap(\.endpointRecord)
    }

    /// Uploads this endpoint's own signed record under the retained
    /// binding authorization.
    public func publishEndpointRecord(_ record: Data) async throws {
        guard let bindingID = await bindingAuthorizationID() else {
            throw CmxIrohTrustBrokerClientError.missingAuthentication
        }
        try await publishEndpointRecord(bindingID: bindingID, record: record)
    }
}
