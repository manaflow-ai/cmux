internal import CMUXMobileCore
internal import Foundation

struct MobileCoreRPCAttachTicketCoverage {
    func ticketCoversTerminalRequest(
        ticket: CmxAttachTicket,
        workspaceSelection: String?,
        terminalSelection: String?
    ) -> Bool {
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        // It covers any workspace/terminal on the paired Mac.
        if ticketWorkspaceID.isEmpty {
            return true
        }
        if let workspaceSelection, workspaceSelection != ticketWorkspaceID {
            return false
        }

        if let ticketTerminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ticketTerminalID.isEmpty {
            return terminalSelection == ticketTerminalID
        }

        return workspaceSelection == ticketWorkspaceID
    }

    func ticketCoversWorkspaceRequest(
        ticket: CmxAttachTicket,
        workspaceSelection: String?
    ) -> Bool {
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        if ticketWorkspaceID.isEmpty {
            return true
        }
        return workspaceSelection == ticketWorkspaceID
    }

    func containsIgnoredAliasParameters(_ params: [String: Any]) -> Bool {
        params["workspaceID"] != nil || params["terminalID"] != nil
    }
}
