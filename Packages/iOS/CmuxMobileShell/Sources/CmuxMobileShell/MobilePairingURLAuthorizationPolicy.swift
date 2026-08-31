import CMUXMobileCore

/// Decides whether a pairing URL needs the in-app scanner's explicit local
/// authorization before its Tailscale destination can receive account auth.
struct MobilePairingURLAuthorizationPolicy {
    static func requiresInAppScan(
        ticket: CmxAttachTicket,
        userEnteredPairingCode: Bool,
        externalURL: Bool
    ) -> Bool {
        guard externalURL, !userEnteredPairingCode else {
            return false
        }
        return ticket.routes.contains { $0.kind == .tailscale }
    }
}
