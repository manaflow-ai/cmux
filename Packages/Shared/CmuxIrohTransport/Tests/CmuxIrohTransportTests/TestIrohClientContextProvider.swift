import CMUXMobileCore
@testable import CmuxIrohTransport

actor TestIrohClientContextProvider: CmxIrohClientContextProvider {
    private let clientContext: CmxIrohClientContext
    private var observedRoutes: [CmxAttachRoute] = []

    init(context: CmxIrohClientContext) {
        clientContext = context
    }

    func context(for route: CmxAttachRoute) -> CmxIrohClientContext {
        observedRoutes.append(route)
        return clientContext
    }

    func routes() -> [CmxAttachRoute] {
        observedRoutes
    }
}
