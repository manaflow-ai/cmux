internal import CMUXMobileCore
internal import Foundation

/// Authorizes Mac-scoped workspace mutations from attach-ticket scope and expiry.
struct MobileShellWorkspaceMutationTicketPolicy {
    let now: Date

    func allowsMacScopedWorkspaceMutations(_ ticket: CmxAttachTicket?) -> Bool {
        guard let ticket,
              ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              !ticket.isExpired(at: now) else {
            return false
        }
        return ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
