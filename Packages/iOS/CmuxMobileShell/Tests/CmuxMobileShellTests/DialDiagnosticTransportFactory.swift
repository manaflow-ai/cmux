import CMUXMobileCore

struct DialDiagnosticTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let failingRouteID: String

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        if route.id == failingRouteID {
            return DialDiagnosticFailingTransport()
        }
        return LivenessTransport(router: router)
    }
}
