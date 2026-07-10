import CMUXMobileCore
@testable import CmuxIrohTransport

actor TestIrohClientContextProvider: CmxIrohClientContextProvider {
    private let clientContext: CmxIrohClientContext
    private var observedRequests: [CmxByteTransportRequest] = []

    init(context: CmxIrohClientContext) {
        clientContext = context
    }

    func context(for request: CmxByteTransportRequest) -> CmxIrohClientContext {
        observedRequests.append(request)
        return clientContext
    }

    func requests() -> [CmxByteTransportRequest] {
        observedRequests
    }
}
