public import CMUXMobileCore

/// Fail-closed authorization seam for the first control stream on a connection.
public protocol CmxIrohAdmissionAuthorizing: Sendable {
    /// Authorizes one authenticated connection.
    ///
    /// - Parameters:
    ///   - credential: The in-band admission proof, or `nil` when the client
    ///     requests allowlist admission of its TLS-proven EndpointID.
    ///   - authenticatedPeerID: The remote identity proven by the QUIC handshake.
    func authorize(
        credential: CmxIrohAdmissionCredential?,
        authenticatedPeerID: CmxIrohPeerIdentity
    ) async -> CmxIrohAdmissionAuthorization
}
