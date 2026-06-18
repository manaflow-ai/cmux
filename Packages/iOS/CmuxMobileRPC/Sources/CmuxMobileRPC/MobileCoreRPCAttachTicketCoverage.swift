internal import CMUXMobileCore
internal import Foundation

struct MobileCoreRPCAttachTicketCoverage {
    func ticketCoversTerminalRequest(
        ticket: CmxAttachTicket,
        requestedWorkspaceID: String?,
        requestedTerminalID: String?
    ) -> Bool {
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        // It covers any workspace/terminal on the paired Mac.
        if ticketWorkspaceID.isEmpty {
            return true
        }
        if let requestedWorkspaceID, requestedWorkspaceID != ticketWorkspaceID {
            return false
        }

        if let ticketTerminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ticketTerminalID.isEmpty {
            return requestedTerminalID == ticketTerminalID
        }

        return requestedWorkspaceID == ticketWorkspaceID
    }

    func ticketCoversWorkspaceRequest(
        ticket: CmxAttachTicket,
        requestedWorkspaceID: String?
    ) -> Bool {
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        if ticketWorkspaceID.isEmpty {
            return true
        }
        return requestedWorkspaceID == ticketWorkspaceID
    }

    func containsIgnoredAliasParameters(_ params: [String: Any]) -> Bool {
        params["workspaceID"] != nil || params["terminalID"] != nil
    }
}
