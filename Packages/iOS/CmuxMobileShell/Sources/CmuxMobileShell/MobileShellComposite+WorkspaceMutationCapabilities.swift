internal import CMUXMobileCore
internal import CmuxMobileRPC
internal import Foundation

extension MobileShellComposite {
    /// Whether the active ticket was issued with Mac-wide mutation scope.
    ///
    /// Menu discovery depends on stable scope, not the ticket's short-lived
    /// expiry. The mutation methods still call
    /// ``allowsMacScopedWorkspaceMutations`` immediately before sending, so an
    /// expired credential fails closed without silently removing supported
    /// actions from an already-visible workspace list.
    var hasMacScopedWorkspaceMutationTicketScope: Bool {
        let ticket = activeTicket ?? remoteClient?.attachTicket
        return MobileShellWorkspaceMutationTicketPolicy(now: runtime?.now() ?? Date())
            .hasMacScopedWorkspaceMutationScope(ticket)
    }

    var allowsMacScopedWorkspaceMutations: Bool {
        allowsMacScopedWorkspaceMutations(targetClient: nil)
    }

    func allowsMacScopedWorkspaceMutations(targetClient: MobileCoreRPCClient?) -> Bool {
        let ticket = activeTicket ?? targetClient?.attachTicket
        return MobileShellWorkspaceMutationTicketPolicy(now: runtime?.now() ?? Date())
            .allowsMacScopedWorkspaceMutations(ticket)
    }
}
