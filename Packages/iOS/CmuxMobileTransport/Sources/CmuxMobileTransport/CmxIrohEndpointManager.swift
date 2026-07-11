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
    private var bindingGeneration = UUID()
    private var bindingTask: Task<CmxIrohEndpointReference, any Error>?

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

    func boundEndpoint() async throws -> CmxIrohEndpointReference {
        if let endpoint {
            return endpoint
        }

        let generation: UUID
        let task: Task<CmxIrohEndpointReference, any Error>
        if let bindingTask {
            generation = bindingGeneration
            task = bindingTask
        } else {
            generation = UUID()
            bindingGeneration = generation
            let keyProvider = keyProvider
            let ffiClient = ffiClient
            let enableRelay = enableRelay
            let acceptConnections = acceptConnections
            task = Task.detached(priority: .userInitiated) {
                let secretKey = try keyProvider.secretKey()
                do {
                    return try ffiClient.bindEndpoint(
                        secretKey: secretKey,
                        enableRelay: enableRelay,
                        acceptConnections: acceptConnections
                    )
                } catch let failure as CmxIrohFailure {
                    throw CmxIrohByteTransportError.bindFailed(failure)
                }
            }
            bindingTask = task
        }

        do {
            let candidate = try await task.value
            guard generation == bindingGeneration else {
                ffiClient.close(endpoint: candidate)
                throw CancellationError()
            }
            bindingTask = nil
            endpoint = candidate
            try Task.checkCancellation()
            return candidate
        } catch {
            if generation == bindingGeneration {
                bindingTask = nil
            }
            throw error
        }
    }

    /// Closes and forgets the current bound endpoint, if any.
    public func closeEndpoint() {
        bindingTask?.cancel()
        bindingTask = nil
        bindingGeneration = UUID()
        guard let endpoint else {
            return
        }
        self.endpoint = nil
        ffiClient.close(endpoint: endpoint)
    }
}
