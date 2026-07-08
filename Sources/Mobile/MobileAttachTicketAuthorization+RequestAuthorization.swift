import CMUXMobileCore
import Foundation

// Attach-ticket scoping for mobile RPC requests.
//
// The attach ticket pins a request to a workspace (and optionally a single
// terminal). These checks decide whether a given `MobileHostRPCRequest` stays
// inside the ticket's scope. The Stack same-account gate in
// `MobileHostService.authorizationError(for:)` remains the authoritative
// authorization; this is scope enforcement only.
extension MobileAttachTicketAuthorization {
    func authorizationError(
        for request: MobileHostRPCRequest
    ) -> MobileHostRPCError? {
        let workspaceSelection = Self.stringParamSelection(
            request.params,
            keys: ["workspace_id"]
        )
        let terminalSelection = Self.stringParamSelection(
            request.params,
            keys: ["surface_id", "terminal_id", "tab_id"]
        )
        if workspaceSelection.hasConflict || terminalSelection.hasConflict {
            return Self.scopedTicketError
        }
        if Self.containsIgnoredAliasParameters(request.params) {
            return Self.scopedTicketError
        }

        switch request.method {
        case "mobile.workspace.list", "workspace.list":
            return nil
        case "workspace.create":
            guard request.params["group_id"] == nil || request.params["group_id"] is NSNull else {
                return macScopedWorkspaceMutationAuthorizationError()
            }
            return nil
        case "workspace.move":
            return macScopedWorkspaceMutationAuthorizationError(workspaceSelection: workspaceSelection.value)
        case "workspace.action", "workspace.close":
            return workspaceAuthorizationError(workspaceSelection: workspaceSelection.value)
        case "workspace.group.action":
            return macScopedWorkspaceMutationAuthorizationError()
        case "workspace.group.collapse", "workspace.group.expand":
            // Display-only group state. Keyed by `group_id` (not a workspace or
            // terminal selection), so it is Mac-scoped like the workspace list and
            // not constrained by the ticket's workspace/terminal pin. The Stack
            // same-account gate in `authorizationError` remains authoritative.
            return nil
        case "mobile.terminal.create", "terminal.create":
            return nil
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.replay", "terminal.replay",
             "mobile.terminal.viewport", "terminal.viewport",
             "mobile.terminal.scroll", "terminal.scroll":
            return terminalAuthorizationError(
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "mobile.events.subscribe", "mobile.events.unsubscribe":
            return nil
        case "mobile.host.status":
            return nil
        default:
            return Self.scopedTicketError
        }
    }

    static func authorizationError(
        ticket: CmxAttachTicket,
        request: MobileHostRPCRequest
    ) -> MobileHostRPCError? {
        MobileAttachTicketAuthorization(
            ticket: ticket,
            createdWorkspaceIDs: [],
            createdTerminalIDs: []
        ).authorizationError(for: request)
    }

    private func terminalAuthorizationError(
        workspaceSelection: String?,
        terminalSelection: String?
    ) -> MobileHostRPCError? {
        if let terminalSelection,
           createdTerminalIDs.contains(terminalSelection) {
            return nil
        }
        if let workspaceSelection,
           createdWorkspaceIDs.contains(workspaceSelection) {
            return nil
        }

        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        // Allow any workspace/terminal under it.
        if ticketWorkspaceID.isEmpty {
            return nil
        }
        if let workspaceSelection, workspaceSelection != ticketWorkspaceID {
            return Self.scopedTicketError
        }

        if let terminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            guard terminalSelection == terminalID else {
                return Self.scopedTicketError
            }
            return nil
        }

        guard workspaceSelection == ticketWorkspaceID else {
            return Self.scopedTicketError
        }
        return nil
    }

    private func workspaceAuthorizationError(workspaceSelection: String?) -> MobileHostRPCError? {
        if let workspaceSelection, createdWorkspaceIDs.contains(workspaceSelection) {
            return nil
        }
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ticketWorkspaceID.isEmpty {
            guard let workspaceSelection, workspaceSelection == ticketWorkspaceID else {
                return Self.scopedTicketError
            }
        }
        return nil
    }

    private func macScopedWorkspaceMutationAuthorizationError(workspaceSelection: String? = nil) -> MobileHostRPCError? {
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ticketWorkspaceID.isEmpty else { return Self.scopedTicketError }
        return workspaceAuthorizationError(workspaceSelection: workspaceSelection)
    }

    private static var scopedTicketError: MobileHostRPCError {
        MobileHostRPCError(
            code: "forbidden",
            message: "Attach ticket is not valid for this workspace or terminal."
        )
    }

    private static func containsIgnoredAliasParameters(_ params: [String: Any]) -> Bool {
        params["workspaceID"] != nil || params["terminalID"] != nil
    }

    private static func stringParamSelection(
        _ params: [String: Any],
        keys: [String]
    ) -> StringParamSelection {
        var selected: String?
        for key in keys {
            if let value = params[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if let selected, selected != trimmed {
                        return StringParamSelection(value: selected, hasConflict: true)
                    }
                    selected = selected ?? trimmed
                }
            }
        }
        return StringParamSelection(value: selected, hasConflict: false)
    }

    private struct StringParamSelection {
        let value: String?
        let hasConflict: Bool
    }
}
