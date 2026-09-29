import CMUXMobileCore

/// Reports transport construction without changing the wrapped factory's behavior.
struct ObservedReconnectTransportFactory: CmxByteTransportFactory {
    let base: any CmxByteTransportFactory
    let didMake: @Sendable () -> Void

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        let transport = try base.makeTransport(for: route)
        didMake()
        return transport
    }
}
