import CMUXMobileCore

struct CloseReconcileTransportFactory: CmxByteTransportFactory {
    let router: CloseReconcileHostRouter

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        CloseReconcileTransport(router: router)
    }
}
