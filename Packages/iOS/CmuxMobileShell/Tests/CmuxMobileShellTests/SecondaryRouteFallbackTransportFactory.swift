import CMUXMobileCore

struct SecondaryRouteFallbackTransportFactory: CmxByteTransportFactory {
    enum Failure: Error {
        case unreachablePreferredRoute
    }

    let router: LivenessHostRouter
    let box: TransportBox
    let attempts: RouteAttemptRecorder

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        attempts.record(route.kind)
        guard route.kind != .tailscale else {
            throw Failure.unreachablePreferredRoute
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}
