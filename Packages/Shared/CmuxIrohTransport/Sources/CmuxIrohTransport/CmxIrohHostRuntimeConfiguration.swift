/// Stable, account-scoped inputs for one Mac Iroh host lifecycle.
public struct CmxIrohHostRuntimeConfiguration: Equatable, Sendable {
    public let deviceID: String
    public let appInstanceID: String
    public let tag: String
    public let displayName: String?
    public let identity: CmxIrohIdentityMaterial
    public let pairingEnabled: Bool
    public let capabilities: [String]
    public let managedRelayURLs: Set<String>
    public let cachedRelayCredential: CmxIrohRelayTokenResponse?

    public init(
        deviceID: String,
        appInstanceID: String,
        tag: String,
        displayName: String?,
        identity: CmxIrohIdentityMaterial,
        pairingEnabled: Bool,
        capabilities: [String],
        managedRelayURLs: Set<String>,
        cachedRelayCredential: CmxIrohRelayTokenResponse? = nil
    ) {
        self.deviceID = deviceID.lowercased()
        self.appInstanceID = appInstanceID.lowercased()
        self.tag = tag
        self.displayName = displayName
        self.identity = identity
        self.pairingEnabled = pairingEnabled
        self.capabilities = capabilities
        self.managedRelayURLs = managedRelayURLs
        self.cachedRelayCredential = cachedRelayCredential
    }
}
