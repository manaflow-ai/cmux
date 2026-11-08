/// Fully resolved relay configuration safe to install on an Iroh endpoint.
public struct CmxIrohEffectiveRelayPolicy: Equatable, Sendable {
    /// Exact endpoint relay allowlist and available credentials.
    public let endpointRelayProfile: CmxIrohEndpointRelayProfile

    /// Verified managed policy snapshot, absent for custom and unavailable modes.
    public let managedSnapshot: CmxIrohRelayPolicySnapshot?

    /// Latest verified managed catalog, retained even when custom or direct-only is active.
    public let managedPolicy: CmxIrohManagedRelayPolicy?

    /// Complete account configuration requested by the broker.
    public let requestedConfiguration: CmxIrohAccountRelayConfiguration?

    /// Active preference derived from ``requestedConfiguration``.
    public var requestedPreference: CmxIrohAccountRelayPreference? {
        requestedConfiguration?.activePreference
    }

    /// Preference subset that could safely be honored.
    public let effectivePreference: CmxIrohAccountRelayPreference?

    /// Requested managed IDs that are absent from the verified policy.
    public let staleRelayIDs: Set<String>

    /// Custom relay IDs whose required device-local token is absent.
    public let missingCredentialRelayIDs: Set<String>

    /// Origin and availability of the endpoint profile.
    public let source: CmxIrohRelayPolicySource

    /// Whether the managed policy came from the last-known-good cache.
    public let usedCachedPolicy: Bool

    /// Monotonic broker preference revision, when one was restored.
    public let preferenceRevision: Int64?

    /// The endpoint-scoped credential returned with this exact broker policy.
    ///
    /// Kept internal so tokens cannot cross the transport/settings boundary.
    let relayBootstrap: CmxIrohRelayTokenResponse?

    init(
        endpointRelayProfile: CmxIrohEndpointRelayProfile,
        managedSnapshot: CmxIrohRelayPolicySnapshot?,
        managedPolicy: CmxIrohManagedRelayPolicy?,
        requestedConfiguration: CmxIrohAccountRelayConfiguration?,
        effectivePreference: CmxIrohAccountRelayPreference?,
        staleRelayIDs: Set<String> = [],
        missingCredentialRelayIDs: Set<String> = [],
        source: CmxIrohRelayPolicySource,
        usedCachedPolicy: Bool,
        preferenceRevision: Int64?,
        relayBootstrap: CmxIrohRelayTokenResponse? = nil
    ) {
        self.endpointRelayProfile = endpointRelayProfile
        self.managedSnapshot = managedSnapshot
        self.managedPolicy = managedPolicy
        self.requestedConfiguration = requestedConfiguration
        self.effectivePreference = effectivePreference
        self.staleRelayIDs = staleRelayIDs
        self.missingCredentialRelayIDs = missingCredentialRelayIDs
        self.source = source
        self.usedCachedPolicy = usedCachedPolicy
        self.preferenceRevision = preferenceRevision
        self.relayBootstrap = relayBootstrap
    }
}
