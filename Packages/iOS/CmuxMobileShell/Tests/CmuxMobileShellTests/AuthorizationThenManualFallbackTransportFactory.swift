import CMUXMobileCore

struct AuthorizationThenManualFallbackTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let box: TransportBox
    let attempts: RouteAttemptRecorder

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        attempts.record(route.kind)
        if route.kind == .tailscale {
            return AuthorizationFailingTransport()
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}
