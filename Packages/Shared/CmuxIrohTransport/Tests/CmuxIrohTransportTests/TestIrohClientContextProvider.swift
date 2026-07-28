import CMUXMobileCore
@testable import CmuxIrohTransport

actor TestIrohClientContextProvider: CmxIrohClientContextProvider {
    private let clientContext: CmxIrohClientContext
    private let fallbackContext: CmxIrohClientContext?
    private var observedRequests: [CmxByteTransportRequest] = []
    private var fallbackRequestCount = 0
    private var authorizations: [CmxIrohPrivateFallbackAuthorization] = []

    init(
        context: CmxIrohClientContext,
        fallbackContext: CmxIrohClientContext? = nil
    ) {
        clientContext = context
        self.fallbackContext = fallbackContext
    }

    func context(for request: CmxByteTransportRequest) -> CmxIrohClientContext {
        observedRequests.append(request)
        return clientContext
    }

    func requests() -> [CmxByteTransportRequest] {
        observedRequests
    }

    func contextWithPrivateFallback(
        for _: CmxByteTransportRequest,
        basedOn context: CmxIrohClientContext
    ) -> CmxIrohClientContext {
        fallbackRequestCount += 1
        return fallbackContext ?? context
    }

    func validatePrivateFallback(
        _ authorization: CmxIrohPrivateFallbackAuthorization
    ) {
        authorizations.append(authorization)
    }

    func observedFallbackRequestCount() -> Int { fallbackRequestCount }
    func observedAuthorizations() -> [CmxIrohPrivateFallbackAuthorization] { authorizations }
}
