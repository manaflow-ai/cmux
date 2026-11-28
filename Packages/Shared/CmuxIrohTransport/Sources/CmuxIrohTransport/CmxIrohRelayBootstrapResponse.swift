/// Relay credential and signed policy returned by one bootstrap request.
public struct CmxIrohRelayBootstrapResponse: Equatable, Sendable {
    /// Managed relay credential, absent for custom or direct-only preferences.
    public let relayToken: CmxIrohRelayTokenResponse?

    /// Signed policy and account preference resolved by the broker.
    public let relayPolicy: CmxIrohRelayPolicyResponse

    /// Creates one validated bootstrap response.
    public init(
        relayToken: CmxIrohRelayTokenResponse?,
        relayPolicy: CmxIrohRelayPolicyResponse
    ) {
        self.relayToken = relayToken
        self.relayPolicy = relayPolicy
    }
}
