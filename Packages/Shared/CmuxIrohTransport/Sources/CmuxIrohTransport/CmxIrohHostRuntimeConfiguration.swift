/// Stable, account-scoped inputs for one Mac Iroh host lifecycle.
public struct CmxIrohHostRuntimeConfiguration: Equatable, Sendable {
    public let deviceID: String
    public let appInstanceID: String
    public let tag: String
    public let displayName: String?
    public let identity: CmxIrohIdentityMaterial
    public let pairingEnabled: Bool
    public let capabilities: [String]
    /// The UDP bind behavior applied to every endpoint generation.
    public let bindPolicy: CmxIrohEndpointBindPolicy
    public let managedRelayURLs: Set<String>
    public let cachedRelayCredential: CmxIrohRelayTokenResponse?
    /// A previously verified offline policy considered only after broker connectivity failure.
    public let cachedHostPolicy: CmxIrohCachedHostPolicy?

    /// Creates stable inputs for one Mac host runtime lifecycle.
    ///
    /// - Parameters:
    ///   - deviceID: The account device's lowercase UUID.
    ///   - appInstanceID: The current app-instance UUID.
    ///   - tag: The broker registration build tag.
    ///   - displayName: The optional user-visible Mac name.
    ///   - identity: The stable Iroh secret and generation.
    ///   - pairingEnabled: Whether same-account pairing is enabled.
    ///   - capabilities: The complete host capability set.
    ///   - bindPolicy: The UDP bind behavior, ephemeral by default.
    ///   - managedRelayURLs: The exact managed relay allowlist.
    ///   - cachedRelayCredential: A validated relay bootstrap for this endpoint.
    ///   - cachedHostPolicy: A policy previously verified by ``CmxIrohHostPolicyCache``.
    public init(
        deviceID: String,
        appInstanceID: String,
        tag: String,
        displayName: String?,
        identity: CmxIrohIdentityMaterial,
        pairingEnabled: Bool,
        capabilities: [String],
        bindPolicy: CmxIrohEndpointBindPolicy = .ephemeral,
        managedRelayURLs: Set<String>,
        cachedRelayCredential: CmxIrohRelayTokenResponse? = nil,
        cachedHostPolicy: CmxIrohCachedHostPolicy? = nil
    ) {
        self.deviceID = deviceID.lowercased()
        self.appInstanceID = appInstanceID.lowercased()
        self.tag = tag
        self.displayName = displayName
        self.identity = identity
        self.pairingEnabled = pairingEnabled
        self.capabilities = capabilities
        self.bindPolicy = bindPolicy
        self.managedRelayURLs = managedRelayURLs
        self.cachedRelayCredential = cachedRelayCredential
        self.cachedHostPolicy = cachedHostPolicy
    }
}
