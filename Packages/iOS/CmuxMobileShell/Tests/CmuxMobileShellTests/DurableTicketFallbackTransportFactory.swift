import CMUXMobileCore
import CmuxMobileTransport

struct DurableTicketFallbackTransportFactory: CmxByteTransportFactory {
    let router: DurableTicketFallbackRouter

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        DurableTicketFallbackTransport(router: router)
    }
}
