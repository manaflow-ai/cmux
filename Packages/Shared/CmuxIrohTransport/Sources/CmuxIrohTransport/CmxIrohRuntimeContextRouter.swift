import CMUXMobileCore

/// Defers client dials until the runtime installs one exact verified local binding.
actor CmxIrohRuntimeContextRouter: CmxIrohClientContextProvider {
    private var provider: (any CmxIrohClientContextProvider)?

    func install(_ provider: any CmxIrohClientContextProvider) {
        self.provider = provider
    }

    func clear() {
        provider = nil
    }

    func context(for request: CmxByteTransportRequest) async throws -> CmxIrohClientContext {
        guard let provider else {
            throw CmxIrohRegistryContextError.localBindingUnavailable
        }
        return try await provider.context(for: request)
    }

    func contextWithPrivateFallback(
        for request: CmxByteTransportRequest,
        basedOn context: CmxIrohClientContext
    ) async throws -> CmxIrohClientContext {
        guard let provider else {
            throw CmxIrohRegistryContextError.localBindingUnavailable
        }
        return try await provider.contextWithPrivateFallback(
            for: request,
            basedOn: context
        )
    }

    func validatePrivateFallback(
        _ authorization: CmxIrohPrivateFallbackAuthorization
    ) async throws {
        guard let provider else {
            throw CmxIrohPrivateFallbackValidationError.unavailable
        }
        try await provider.validatePrivateFallback(authorization)
    }
}
