internal import CMUXMobileCore
internal import CmuxMobileRPC
internal import Foundation

extension MobileShellComposite {
    var allowsMacScopedWorkspaceMutations: Bool {
        allowsMacScopedWorkspaceMutations(targetClient: nil)
    }

    func allowsMacScopedWorkspaceMutations(targetClient: MobileCoreRPCClient?) -> Bool {
        let ticket = activeTicket ?? targetClient?.attachTicket
        return Self.attachTicketAllowsMacScopedWorkspaceMutations(ticket, now: runtime?.now() ?? Date())
    }

    static func attachTicketAllowsMacScopedWorkspaceMutations(
        _ ticket: CmxAttachTicket?,
        now: Date
    ) -> Bool {
        guard let ticket,
              ticket.authToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              !ticket.isExpired(at: now) else {
            return false
        }
        return ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
