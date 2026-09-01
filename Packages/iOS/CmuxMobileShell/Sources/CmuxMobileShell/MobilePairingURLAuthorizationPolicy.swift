import CMUXMobileCore

/// Decides whether a pairing URL needs the in-app scanner's explicit local
/// authorization before its Tailscale destination can receive account auth.
struct MobilePairingURLAuthorizationPolicy {
    /// Returns `true` for a tokenless Tailscale URL opened outside cmux.
    ///
    /// Legacy attach URLs may carry an attach token that already authorizes
    /// the route, so those links remain compatible when opened externally.
    func requiresInAppScan(
        ticket: CmxAttachTicket,
        userEnteredPairingCode: Bool,
        externalURL: Bool
    ) -> Bool {
        guard externalURL,
              !userEnteredPairingCode,
              ticket.authToken == nil else {
            return false
        }
        return ticket.routes.contains { $0.kind == .tailscale }
    }
}
