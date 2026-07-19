import CMUXMobileCore
import Foundation

struct ManualFallbackApprovalTransportFactory: CmxByteTransportFactory {
    let router: LivenessHostRouter
    let box: TransportBox
    var attempts: RouteAttemptRecorder?
    var failingRouteKind: CmxAttachTransportKind = .tailscale

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        attempts?.record(route.kind)
        if route.kind == failingRouteKind {
            return SlowIgnoringCancellationTransport()
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}
