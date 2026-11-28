public import CMUXMobileCore

/// Fail-closed authorization seam for the first control stream on a connection.
public protocol CmxIrohAdmissionAuthorizing: Sendable {
    func authorize(
        credential: CmxIrohAdmissionCredential,
        authenticatedPeerID: CmxIrohPeerIdentity
    ) async -> CmxIrohAdmissionAuthorization
}
