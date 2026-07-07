import CMUXMobileCore
import CmuxMobileRPC

struct CountingSlowIgnoringCancellationTransportFactory: CmxByteTransportFactory {
    let transport: CountingSlowIgnoringCancellationTransport

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        transport
    }
}
