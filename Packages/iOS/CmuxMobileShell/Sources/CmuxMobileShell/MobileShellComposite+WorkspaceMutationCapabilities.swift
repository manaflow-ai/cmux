internal import CMUXMobileCore
internal import CmuxMobileRPC
internal import Foundation

extension MobileShellComposite {
    var allowsMacScopedWorkspaceMutations: Bool {
        allowsMacScopedWorkspaceMutations(targetClient: nil)
    }

    func allowsMacScopedWorkspaceMutations(targetClient: MobileCoreRPCClient?) -> Bool {
        let ticket = activeTicket ?? targetClient?.attachTicket
        return MobileShellWorkspaceMutationTicketPolicy(now: runtime?.now() ?? Date())
            .allowsMacScopedWorkspaceMutations(ticket)
    }
}
