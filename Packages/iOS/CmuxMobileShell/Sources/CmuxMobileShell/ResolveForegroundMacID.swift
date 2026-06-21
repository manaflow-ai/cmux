import CMUXMobileCore

/// Resolve the id used to key the foreground Mac's workspace state.
func resolveForegroundMacID(ticket: CmxAttachTicket, hint: String?) -> String {
    if let hint, !hint.isEmpty, !hint.hasPrefix("manual-") { return hint }
    return ticket.macDeviceID
}
