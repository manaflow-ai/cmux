internal import CMUXMobileCore
internal import Foundation

/// Authorizes Mac-scoped workspace mutations from attach-ticket scope and expiry.
struct MobileShellWorkspaceMutationTicketPolicy {
    let now: Date

    func hasMacScopedWorkspaceMutationScope(_ ticket: CmxAttachTicket?) -> Bool {
        guard let ticket,
              ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        return ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// - Parameters:
    ///   - ticket: The connection's attach ticket, if any.
    ///   - hostAuthorizesByAccount: Whether the host advertises
    ///     `workspace.mutations.account_auth.v1`: the signed-in Stack account
    ///     authorizes Mac-scoped mutations. Callers omit attach-ticket context
    ///     for these requests so an older saved workspace route cannot narrow
    ///     them. Legacy hosts reject these verbs without a current mac-scoped
    ///     ticket, so the client fails closed for them.
    func allowsMacScopedWorkspaceMutations(
        _ ticket: CmxAttachTicket?,
        hostAuthorizesByAccount: Bool
    ) -> Bool {
        if hostAuthorizesByAccount {
            return true
        }
        guard let ticket,
              ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              !ticket.isExpired(at: now) else {
            // No current token: nothing narrows the connection. Mirrors the
            // host, where a missing or expired token cannot narrow anything
            // and the account gate is the sole authority.
            return hostAuthorizesByAccount
        }
        return ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func allowsMacScopedWorkspaceMutations(_ ticket: CmxAttachTicket?) -> Bool {
        allowsMacScopedWorkspaceMutations(ticket, hostAuthorizesByAccount: false)
    }
}
