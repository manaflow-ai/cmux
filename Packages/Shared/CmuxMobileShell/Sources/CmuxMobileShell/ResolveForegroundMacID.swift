import CMUXMobileCore

/// Resolve the id used to key the foreground Mac's workspace state.
extension CmxAttachTicket {
    func foregroundMacID(hint: String?) -> String {
        // A real ticket id names the Mac that actually answered this connect
        // and must win even over a contradicting stored-Mac hint: reconnect
        // iterates every persisted route, and a stale endpoint can be served
        // by a different Mac. Ticket persistence already keys by the real id,
        // so keying the foreground by the hint would split the identity. The
        // hint fills in only for synthetic `manual-…` fallback tickets and
        // id-less minimal pairing tickets.
        if !macDeviceID.isEmpty, !macDeviceID.hasPrefix("manual-") { return macDeviceID }
        if let hint, !hint.isEmpty, !hint.hasPrefix("manual-") { return hint }
        return macDeviceID
    }
}
