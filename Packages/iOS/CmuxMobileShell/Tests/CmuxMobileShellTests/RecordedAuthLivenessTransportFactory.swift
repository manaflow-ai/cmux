import CMUXMobileCore

struct RecordedAuthLivenessTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let tokenSink: RecordedAuthTokenSink

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        _ = route
        return RecordedAuthLivenessTransport(router: router, tokenSink: tokenSink)
    }
}
