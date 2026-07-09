import CMUXMobileCore
import CmuxMobileRPC

struct RouteSelectiveFailureTransportFactory: CmxByteTransportFactory {
    let failingRouteID: String
    let router: LivenessHostRouter
    let box: TransportBox

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        if route.id == failingRouteID {
            return SlowIgnoringCancellationTransport()
        }
        let transport = LivenessTransport(router: router)
        box.set(transport)
        return transport
    }
}
