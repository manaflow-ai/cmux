public import Foundation

/// Owns the phone-side iroh endpoint for the current foreground lifecycle.
///
/// The endpoint is bound lazily on first use and can be closed when the app
/// enters the background. Swift owns the persisted secret key; the FFI only
/// receives it while binding the endpoint.
public actor CmxIrohEndpointManager {
    private let keyProvider: CmxIrohSecretKeyProvider
    private let ffiClient: any CmxIrohFFIClient
    private let enableRelay: Bool
    private let acceptConnections: Bool
    private var endpoint: CmxIrohEndpointReference?

    /// Creates a production endpoint manager using the iOS Keychain.
    public init(
        enableRelay: Bool = true,
        acceptConnections: Bool = false
    ) {
        let ffiClient = CmxIrohSystemFFIClient()
        self.init(
            keyProvider: CmxIrohSecretKeyProvider(
                store: CmxIrohKeychainSecretStore(),
                generate: { try ffiClient.generateSecretKey() }
            ),
            ffiClient: ffiClient,
            enableRelay: enableRelay,
            acceptConnections: acceptConnections
        )
    }

    init(
        keyProvider: CmxIrohSecretKeyProvider,
        ffiClient: any CmxIrohFFIClient,
        enableRelay: Bool = true,
        acceptConnections: Bool = false
    ) {
        self.keyProvider = keyProvider
        self.ffiClient = ffiClient
        self.enableRelay = enableRelay
        self.acceptConnections = acceptConnections
    }

    func boundEndpoint() throws -> CmxIrohEndpointReference {
        if let endpoint {
            return endpoint
        }
        let secretKey = try keyProvider.secretKey()
        do {
            let endpoint = try ffiClient.bindEndpoint(
                secretKey: secretKey,
                enableRelay: enableRelay,
                acceptConnections: acceptConnections
            )
            self.endpoint = endpoint
            return endpoint
        } catch let failure as CmxIrohFailure {
            throw CmxIrohByteTransportError.bindFailed(failure)
        }
    }

    /// Closes and forgets the current bound endpoint, if any.
    public func closeEndpoint() {
        guard let endpoint else {
            return
        }
        self.endpoint = nil
        ffiClient.close(endpoint: endpoint)
    }
}
