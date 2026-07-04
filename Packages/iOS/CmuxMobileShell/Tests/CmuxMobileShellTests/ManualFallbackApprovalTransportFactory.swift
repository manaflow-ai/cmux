import CMUXMobileCore

struct ManualFallbackApprovalTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let box: TransportBox

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        if route.kind == .tailscale {
            return SlowIgnoringCancellationTransport()
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}
