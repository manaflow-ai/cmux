import CMUXMobileCore

/// Resolve the id used to key the foreground Mac's workspace state.
extension CmxAttachTicket {
    func foregroundMacID(hint: String?) -> String {
        if let hint, !hint.isEmpty, !hint.hasPrefix("manual-") { return hint }
        return macDeviceID
    }
}
