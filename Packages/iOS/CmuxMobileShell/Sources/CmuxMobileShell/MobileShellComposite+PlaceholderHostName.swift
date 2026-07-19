import CMUXMobileCore

extension MobileShellComposite {
    /// The name shown for the Mac until `mobile.host.status` reports the real
    /// one: the ticket's display name, then its device id, then the dialed
    /// route's host (a minimal pairing code carries neither name nor id, so the
    /// route hostname is the best available placeholder).
    func placeholderHostName(
        for ticket: CmxAttachTicket,
        firstRoute: CmxAttachRoute
    ) -> String {
        if let name = ticket.macDisplayName, !name.isEmpty {
            return name
        }
        if !ticket.macDeviceID.isEmpty {
            return ticket.macDeviceID
        }
        if case let .hostPort(host, _) = firstRoute.endpoint {
            return host
        }
        return ""
    }
}
