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
        if ticketHasTerminalScope(ticket) {
            return false
        }

        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        if ticketWorkspaceID.isEmpty {
            return true
        }
        return workspaceSelection == ticketWorkspaceID
    }

    private func ticketHasTerminalScope(_ ticket: CmxAttachTicket) -> Bool {
        ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func ticketCoversWorkspaceCreateRequest(ticket: CmxAttachTicket) -> Bool {
        ticketCoversMacWideRequest(ticket: ticket)
    }

    func ticketCoversMacWideRequest(ticket: CmxAttachTicket) -> Bool {
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return ticketWorkspaceID.isEmpty
    }

    func ticketCoversTerminalCreateRequest(
        ticket: CmxAttachTicket,
        workspaceSelection: String?,
        terminalSelection: String?
    ) -> Bool {
        if terminalSelection != nil {
            return false
        }

        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        // It covers creating terminals in any workspace on the paired Mac.
        if ticketWorkspaceID.isEmpty {
            return true
        }

        if let ticketTerminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ticketTerminalID.isEmpty {
            return false
        }

        return workspaceSelection == ticketWorkspaceID
    }

    func containsIgnoredAliasParameters(_ params: [String: Any]) -> Bool {
        params["workspaceID"] != nil || params["terminalID"] != nil
    }
}
