import CMUXMobileCore
import Foundation

struct SecondaryRouteFallbackTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let box: TransportBox
    let attempts: RouteAttemptRecorder

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        attempts.record(route.kind)
        guard route.kind != .tailscale else {
            throw URLError(.cannotConnectToHost)
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}
