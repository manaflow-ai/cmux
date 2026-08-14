import CMUXMobileCore
@testable import CmuxIrohTransport

actor TestIrohClientContextProvider: CmxIrohClientContextProvider {
    struct ObservedDialFailure: Sendable {
        let request: CmxByteTransportRequest
        let dialPlan: CmxIrohDialPlan
        let failure: DiagnosticFailureKind
    }

    private let clientContext: CmxIrohClientContext
    private let fallbackContext: CmxIrohClientContext?
    private var observedRequests: [CmxByteTransportRequest] = []
    private var fallbackRequestCount = 0
    private var authorizations: [CmxIrohPrivateFallbackAuthorization] = []
    private var dialFailures: [ObservedDialFailure] = []

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

    // Declared `async` to match the protocol requirement exactly: an async
    // caller would otherwise prefer the protocol-extension no-op over a
    // synchronous member (SE-0296 overload ranking).
    func noteDialFailure(
        for request: CmxByteTransportRequest,
        dialPlan: CmxIrohDialPlan,
        failure: DiagnosticFailureKind
    ) async {
        dialFailures.append(ObservedDialFailure(
            request: request,
            dialPlan: dialPlan,
            failure: failure
        ))
    }

    func observedFallbackRequestCount() -> Int { fallbackRequestCount }
    func observedAuthorizations() -> [CmxIrohPrivateFallbackAuthorization] { authorizations }
    func observedDialFailures() -> [ObservedDialFailure] { dialFailures }
}
