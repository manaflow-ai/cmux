import CMUXMobileCore

struct AttachTicketSuccessTransportFactory: CmxByteTransportFactory {
    let ticket: CmxAttachTicket

    func makeTransport(for route: CmxAttachRoute) throws -> any CmxByteTransport {
        AttachTicketSuccessTransport(ticket: ticket)
    }
}
