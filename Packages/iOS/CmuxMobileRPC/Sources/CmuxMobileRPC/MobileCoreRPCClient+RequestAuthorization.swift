import CMUXMobileCore
import Foundation

extension MobileCoreRPCClient {
    static func requestNeedsStackAuthFallback(
        _ request: [String: Any],
        ticket: CmxAttachTicket
    ) -> Bool {
        guard requestRequiresAuth(request) else {
            return false
        }
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = request["params"] as? [String: Any] ?? [:]
        let workspaceSelection = stringParamSelection(params, keys: ["workspace_id"])
        let terminalSelection = stringParamSelection(params, keys: ["surface_id", "terminal_id", "tab_id"])
        let ticketCoverage = MobileCoreRPCAttachTicketCoverage()
        if workspaceSelection.hasConflict
            || terminalSelection.hasConflict
            || ticketCoverage.containsIgnoredAliasParameters(params) {
            return true
        }

        switch method {
        case "mobile.workspace.list", "workspace.list":
            return false
        case "workspace.create":
            return false
        case "workspace.action", "workspace.close":
            return !ticketCoverage.ticketCoversWorkspaceRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value
            )
        case "workspace.move", "workspace.group.action", "workspace.group.create":
            // These mutations are Mac-scoped. Preserve attach-ticket context so
            // the host can reject workspace-scoped tickets rather than receiving
            // a Stack-only request.
            return false
        case "mobile.terminal.create", "terminal.create":
            return false
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.replay", "terminal.replay",
             "mobile.terminal.viewport", "terminal.viewport",
             "mobile.terminal.artifact.scan",
             "mobile.terminal.artifact.stat",
             "mobile.terminal.artifact.fetch",
             "mobile.terminal.artifact.thumbnail":
            return !ticketCoverage.ticketCoversTerminalRequest(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "mobile.events.subscribe", "mobile.events.unsubscribe":
            return false
        default:
            return true
        }
    }

    static func requestRequiresAuth(_ request: [String: Any]) -> Bool {
        let method = (request["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return method != "mobile.host.status"
    }

}

private func stringParamSelection(
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
