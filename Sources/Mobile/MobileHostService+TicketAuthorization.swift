import CMUXMobileCore
import Foundation

extension MobileHostService {
    static func ticketAuthorizationError(
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

    static func ticketAuthorizationError(
        authorization: MobileAttachTicketAuthorization,
        request: MobileHostRPCRequest
    ) -> MobileHostRPCError? {
        let workspaceSelection = stringParamSelection(
            request.params,
            keys: ["workspace_id"]
        )
        let terminalSelection = stringParamSelection(
            request.params,
            keys: ["surface_id", "terminal_id", "tab_id"]
        )
        if workspaceSelection.hasConflict || terminalSelection.hasConflict {
            return scopedTicketError
        }
        if containsIgnoredAliasParameters(request.params) {
            return scopedTicketError
        }

        switch request.method {
        case "mobile.workspace.list", "workspace.list", "mobile.workspace.changes.summary",
             "mobile.directory.list", "mobile.directory.search":
            // List-shaped reads may span the Mac's workspaces; same-account
            // Stack authorization remains the authoritative data-plane gate.
            return nil
        case "mobile.sync.fetch":
            // Cursor-based read of the same Mac-scoped list state as
            // `mobile.workspace.list`; carries no workspace/terminal selection.
            return nil
        case "mobile.workspace.changes.files",
             "mobile.workspace.changes.file_diff",
             "mobile.workspace.changes.file_stat",
             "mobile.workspace.changes.file_fetch":
            // Single-workspace reads honor a workspace-scoped attach ticket in
            // the same way as workspace.action / workspace.close below.
            return ticketWorkspaceAuthorizationError(
                authorization: authorization,
                workspaceSelection: workspaceSelection.value
            )
        case "workspace.create":
            guard request.params["group_id"] == nil || request.params["group_id"] is NSNull else {
                return ticketMacScopedWorkspaceMutationAuthorizationError(authorization: authorization)
            }
            return nil
        case "workspace.move":
            return ticketMacScopedWorkspaceMutationAuthorizationError(
                authorization: authorization,
                workspaceSelection: workspaceSelection.value
            )
        case "workspace.action", "workspace.close":
            return ticketWorkspaceAuthorizationError(authorization: authorization, workspaceSelection: workspaceSelection.value)
        case "workspace.group.action", "workspace.group.create":
            return ticketMacScopedWorkspaceMutationAuthorizationError(authorization: authorization)
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
             "mobile.terminal.scroll", "terminal.scroll",
             "mobile.terminal.artifact.scan",
             "mobile.terminal.artifact.stat",
             "mobile.terminal.artifact.fetch",
             "mobile.terminal.artifact.thumbnail",
             "mobile.terminal.artifact.list":
            return ticketTerminalAuthorizationError(
                authorization: authorization,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "notification.feed.list", "notification.feed.mark_read", "notification.feed.mark_unread",
             "notification.feed.mark_all_read":
            // The Stack same-account check (or admitted Iroh peer identity) is
            // the authority for the account-wide feed, just as it is for the
            // account-wide workspace list. An attach ticket only narrows
            // workspace/terminal mutations; letting a legacy scoped ticket
            // narrow this read model would make it less capable than a tokenless
            // persisted pairing from the same authenticated account.
            return nil
        case "mobile.events.subscribe":
            // Subscription payloads are revision-only invalidations. The
            // request already passed connection/account authorization, and the
            // complete topic set is installed atomically, so ticket-scoping one
            // topic here would also disable unrelated terminal live events.
            return nil
        case "mobile.events.unsubscribe":
            return nil
        case "mobile.host.status":
            return nil
        default:
            return scopedTicketError
        }
    }

    private static func ticketTerminalAuthorizationError(authorization: MobileAttachTicketAuthorization, workspaceSelection: String?, terminalSelection: String?) -> MobileHostRPCError? {
        if let terminalSelection,
           authorization.createdTerminalIDs.contains(terminalSelection) {
            return nil
        }
        if let workspaceSelection,
           authorization.createdWorkspaceIDs.contains(workspaceSelection) {
            return nil
        }
        let ticket = authorization.ticket
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing), so allow any workspace/terminal.
        if ticketWorkspaceID.isEmpty { return nil }
        if let workspaceSelection, workspaceSelection != ticketWorkspaceID {
            return scopedTicketError
        }
        if let terminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            guard terminalSelection == terminalID else { return scopedTicketError }
            return nil
        }
        guard workspaceSelection == ticketWorkspaceID else { return scopedTicketError }
        return nil
    }

    private static func ticketWorkspaceAuthorizationError(authorization: MobileAttachTicketAuthorization, workspaceSelection: String?) -> MobileHostRPCError? {
        if let workspaceSelection, authorization.createdWorkspaceIDs.contains(workspaceSelection) { return nil }
        let ticket = authorization.ticket
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ticketWorkspaceID.isEmpty {
            guard let workspaceSelection, workspaceSelection == ticketWorkspaceID else { return scopedTicketError }
        }
        return nil
    }

    private static func ticketMacScopedWorkspaceMutationAuthorizationError(
        authorization: MobileAttachTicketAuthorization,
        workspaceSelection: String? = nil
    ) -> MobileHostRPCError? {
        let ticketWorkspaceID = authorization.ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ticketWorkspaceID.isEmpty else { return scopedTicketError }
        return ticketWorkspaceAuthorizationError(
            authorization: authorization,
            workspaceSelection: workspaceSelection
        )
    }

    static var scopedTicketError: MobileHostRPCError { MobileHostRPCError(code: "forbidden", message: "Attach ticket is not valid for this workspace or terminal.") }

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
