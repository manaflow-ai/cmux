import CMUXMobileCore
import Foundation

extension MobileHostService {
    static func ticketAuthorizationError(
        ticket: CmxAttachTicket,
        request: MobileHostRPCRequest,
        createdWorkspaceIDs: Set<String> = [],
        createdTerminalIDs: Set<String> = []
    ) -> MobileHostRPCError? {
        MobileAttachTicketAuthorization(
            ticket: ticket,
            createdWorkspaceIDs: createdWorkspaceIDs,
            createdTerminalIDs: createdTerminalIDs
        ).authorizationError(for: request)
    }
}
