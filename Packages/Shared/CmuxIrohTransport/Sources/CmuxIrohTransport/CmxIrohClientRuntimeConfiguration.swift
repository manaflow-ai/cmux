/// Stable, account-and-build-scoped inputs for one iOS Iroh lifecycle.
public struct CmxIrohClientRuntimeConfiguration: Equatable, Sendable {
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
    ///   - cachedRelayCredential: A validated cached relay capability.
    public init(
        deviceID: String,
        appInstanceID: String,
        tag: String,
        displayName: String?,
        identity: CmxIrohIdentityMaterial,
        capabilities: [String],
        managedRelayURLs: Set<String>,
        cachedRelayCredential: CmxIrohRelayTokenResponse? = nil
    ) {
        self.deviceID = deviceID.lowercased()
        self.appInstanceID = appInstanceID.lowercased()
        self.tag = tag
        self.displayName = displayName
        self.identity = identity
        self.capabilities = capabilities
        self.managedRelayURLs = managedRelayURLs
        self.cachedRelayCredential = cachedRelayCredential
    }
}
