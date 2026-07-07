import CMUXMobileCore
import Foundation

extension MobileHostService {
    static func ticketAuthorizationError(
        ticket: CmxAttachTicket,
        request: MobileHostRPCRequest
    ) -> MobileHostRPCError? {
        ticketAuthorizationError(
            authorization: MobileAttachTicketAuthorization(
                ticket: ticket,
                createdWorkspaceIDs: [],
                createdTerminalIDs: []
            ),
            request: request
        )
    }

    static func debugTicketAuthorizationError(
        ticket: CmxAttachTicket,
        request: MobileHostRPCRequest,
        createdWorkspaceIDs: Set<String> = [],
        createdTerminalIDs: Set<String> = []
    ) -> MobileHostRPCError? {
        ticketAuthorizationError(
            authorization: MobileAttachTicketAuthorization(
                ticket: ticket,
                createdWorkspaceIDs: createdWorkspaceIDs,
                createdTerminalIDs: createdTerminalIDs
            ),
            request: request
        )
    }
}
