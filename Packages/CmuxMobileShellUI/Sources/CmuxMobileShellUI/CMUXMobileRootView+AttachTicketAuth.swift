import Foundation
import CmuxMobileWorkspace

extension CMUXMobileRootView {
    var hasAttachTicketAuthentication: Bool {
        MobileRootAuthGate.hasAttachTicketAuthentication(
            didAuthenticateWithAttachTicket: didAuthenticateWithAttachTicket,
            hasActiveUnexpiredTicket: store.hasActiveUnexpiredAttachTicket
        )
    }

    var attachTicketAuthenticationExpiry: Date? {
        guard didAuthenticateWithAttachTicket,
              store.activeTicket?.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return store.activeTicket?.expiresAt
    }

    @MainActor
    func clearAttachTicketAuthenticationAtExpiry() async {
        guard let expiresAt = attachTicketAuthenticationExpiry else { return }
        let delay = expiresAt.timeIntervalSince(Date())
        if delay > 0 {
            let milliseconds = Int64((delay * 1_000).rounded(.up))
            do {
                try await ContinuousClock().sleep(for: .milliseconds(milliseconds))
            } catch {
                return
            }
        }
        clearAttachTicketAuthenticationIfNeeded()
    }
}
