internal import CMUXMobileCore

/// Stable, account-scoped inputs for one Mac Iroh host lifecycle.
public struct CmxIrohHostRuntimeConfiguration: Equatable, Sendable {
    /// The authenticated account scope used only for pending-revocation isolation.
    public let accountID: String

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
    /// Optional selected-managed or strict-custom profile for the local endpoint.
    ///
    /// `nil` preserves automatic use of the complete managed fleet.
    public let endpointRelayProfile: CmxIrohEndpointRelayProfile?
    public let cachedRelayCredential: CmxIrohRelayTokenResponse?
    /// A previously verified offline policy considered only after broker connectivity failure.
    public let cachedHostPolicy: CmxIrohCachedHostPolicy?

    /// Creates stable inputs for one Mac host runtime lifecycle.
    ///
    /// - Parameters:
    ///   - accountID: The exact account that owns this host binding.
    ///   - deviceID: The account device's lowercase UUID.
    ///   - appInstanceID: The current app-instance UUID.
    ///   - tag: The broker registration build tag.
    ///   - displayName: The optional user-visible Mac name.
    ///   - identity: The stable Iroh secret and generation.
    ///   - pairingEnabled: Whether same-account pairing is enabled.
    ///   - capabilities: The complete host capability set.
    ///   - bindPolicy: The UDP bind behavior, ephemeral by default.
    ///   - managedRelayURLs: The exact managed relay allowlist.
    ///   - endpointRelayProfile: An optional local selection or custom override.
    ///   - cachedRelayCredential: A validated relay bootstrap for this endpoint.
    ///   - cachedHostPolicy: A policy previously verified by ``CmxIrohHostPolicyCache``.
    public init(
        accountID: String,
        deviceID: String,
        appInstanceID: String,
        tag: String,
        displayName: String?,
        identity: CmxIrohIdentityMaterial,
        pairingEnabled: Bool,
        capabilities: [String],
        bindPolicy: CmxIrohEndpointBindPolicy = .ephemeral,
        managedRelayURLs: Set<String>,
        endpointRelayProfile: CmxIrohEndpointRelayProfile? = nil,
        cachedRelayCredential: CmxIrohRelayTokenResponse? = nil,
        cachedHostPolicy: CmxIrohCachedHostPolicy? = nil
    ) {
        self.accountID = accountID
        self.deviceID = cmxCanonicalDeviceID(deviceID)
        self.appInstanceID = appInstanceID.lowercased()
        self.tag = tag
        self.displayName = displayName
        self.identity = identity
        self.pairingEnabled = pairingEnabled
        self.capabilities = capabilities
        self.bindPolicy = bindPolicy
        self.managedRelayURLs = managedRelayURLs
        self.endpointRelayProfile = endpointRelayProfile
        self.cachedRelayCredential = cachedRelayCredential
        self.cachedHostPolicy = cachedHostPolicy
    }
}
