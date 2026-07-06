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
        createdTerminalIDs: Set<String> = [],
        groupAnchorWorkspaceIDs: [String: String] = [:]
    ) -> MobileHostRPCError? {
        ticketAuthorizationError(
            authorization: MobileAttachTicketAuthorization(
                ticket: ticket,
                createdWorkspaceIDs: createdWorkspaceIDs,
                createdTerminalIDs: createdTerminalIDs
            ),
            request: request,
            groupAnchorWorkspaceIDForGroupID: { groupAnchorWorkspaceIDs[$0] }
        )
    }

    static func groupSelectionWorkspaceID(
        params: [String: Any],
        groupAnchorWorkspaceIDForGroupID: (String) -> String?
    ) -> String? {
        guard let rawGroupID = params["group_id"] as? String else { return nil }
        let trimmedGroupID = rawGroupID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGroupID.isEmpty else { return nil }
        return groupAnchorWorkspaceIDForGroupID(trimmedGroupID)
    }
}
