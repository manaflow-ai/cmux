import CMUXMobileCore

struct HeldAuthorizationFailureTransportFactory: CmxByteTransportFactory {
    let method: String
    let gate: HeldAuthorizationFailureGate
    let router: LivenessHostRouter

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        _ = route
        return HeldAuthorizationFailureTransport(method: method, gate: gate, router: router)
    }
}
