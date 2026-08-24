internal import CMUXMobileCore
internal import CmuxMobileRPC
internal import Foundation

extension MobileShellComposite {
    /// Whether the active ticket was issued with Mac-wide mutation scope.
    ///
    /// Menu discovery depends on stable scope, not the ticket's short-lived
    /// expiry. New hosts authorize by signed-in account after expiry; legacy
    /// hosts keep the existing visible action and surface a failure on use.
    var hasMacScopedWorkspaceMutationTicketScope: Bool {
        let ticket = activeTicket ?? remoteClient?.attachTicket
        return MobileShellWorkspaceMutationTicketPolicy(now: runtime?.now() ?? Date())
            .hasMacScopedWorkspaceMutationScope(ticket)
    }

    var allowsMacScopedWorkspaceMutations: Bool {
        allowsMacScopedWorkspaceMutations(targetClient: nil)
    }

    var discoversMacScopedWorkspaceMutations: Bool {
        hasMacScopedWorkspaceMutationTicketScope || allowsMacScopedWorkspaceMutations
    }

    func allowsMacScopedWorkspaceMutations(targetClient: MobileCoreRPCClient?) -> Bool {
        let ticket = activeTicket ?? targetClient?.attachTicket
        return MobileShellWorkspaceMutationTicketPolicy(now: runtime?.now() ?? Date())
            .allowsMacScopedWorkspaceMutations(
                ticket,
                hostAuthorizesByAccount: hostAuthorizesAccountScopedMutations
            )
    }

    /// Whether the foreground Mac authorizes Mac-scoped workspace mutations by
    /// the signed-in account. Requests using this capability omit attach-ticket
    /// context so a saved workspace route cannot narrow the account authority.
    var hostAuthorizesAccountScopedMutations: Bool {
        supportedHostCapabilities.contains(Self.workspaceMutationAccountAuthCapability)
    }
}
