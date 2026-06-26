import CMUXMobileCore

actor MobileCoreRPCTicketState {
    private var ticket: CmxAttachTicket

    init(ticket: CmxAttachTicket) {
        self.ticket = ticket
    }

    func current() -> CmxAttachTicket {
        ticket
    }

    func replace(with ticket: CmxAttachTicket) {
        self.ticket = ticket
    }
}
