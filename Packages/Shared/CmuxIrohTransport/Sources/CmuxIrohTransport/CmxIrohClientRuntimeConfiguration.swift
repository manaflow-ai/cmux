internal import CMUXMobileCore

/// Stable, account-and-build-scoped inputs for one iOS Iroh lifecycle.
public struct CmxIrohClientRuntimeConfiguration: Equatable, Sendable {
    /// The authenticated account scope used only for device-local policy isolation.
    public let accountID: String

    /// The app-generated UUID shared with the cmux device registry.
    public let deviceID: String

    /// The account-and-build-scoped app-instance UUID.
    public let appInstanceID: String

    /// The release channel or tagged-build scope registered with the broker.
    public let tag: String

    /// The optional user-visible device name.
    public let displayName: String?

    /// The stable endpoint key and monotonic rotation generation.
    public let identity: CmxIrohIdentityMaterial

    /// The bounded application capabilities advertised by this endpoint.
    public let capabilities: [String]

    /// The complete relay fleet trusted by this app build.
    public let managedRelayURLs: Set<String>

    /// Optional selected-managed or strict-custom profile for the local endpoint.
    ///
    /// `nil` preserves automatic use of the complete managed fleet.
    public let endpointRelayProfile: CmxIrohEndpointRelayProfile?

    /// A previously validated endpoint-scoped relay credential, when available.
    public let cachedRelayCredential: CmxIrohRelayTokenResponse?

    /// Creates an immutable iOS client lifecycle configuration.
    ///
    /// Broker-facing validation occurs when ``CmxIrohClientRuntime/start()``
    /// creates the signed registration payload.
    ///
    /// - Parameters:
    ///   - deviceID: The app-generated lowercase device UUID.
    ///   - appInstanceID: The account-and-build-scoped lowercase UUID.
    ///   - tag: The safe release or tagged-build scope.
    ///   - displayName: An optional user-visible device name.
    ///   - identity: The account-scoped endpoint identity material.
    ///   - capabilities: The advertised protocol capabilities.
    ///   - managedRelayURLs: The exact managed relay fleet.
    ///   - endpointRelayProfile: An optional local selection or custom override.
    ///   - cachedRelayCredential: A validated cached relay capability.
    public init(
        accountID: String,
        deviceID: String,
        appInstanceID: String,
        tag: String,
        displayName: String?,
        identity: CmxIrohIdentityMaterial,
        capabilities: [String],
        managedRelayURLs: Set<String>,
        endpointRelayProfile: CmxIrohEndpointRelayProfile? = nil,
        cachedRelayCredential: CmxIrohRelayTokenResponse? = nil
    ) {
        self.accountID = accountID
        self.deviceID = cmxCanonicalDeviceID(deviceID)
        self.appInstanceID = appInstanceID.lowercased()
        self.tag = tag
        self.displayName = displayName
        self.identity = identity
        self.capabilities = capabilities
        self.managedRelayURLs = managedRelayURLs
        self.endpointRelayProfile = endpointRelayProfile
        self.cachedRelayCredential = cachedRelayCredential
    }
}
