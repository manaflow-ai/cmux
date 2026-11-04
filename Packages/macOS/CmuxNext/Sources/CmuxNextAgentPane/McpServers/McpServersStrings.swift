import Foundation

/// The user-facing strings of Settings > MCP Servers (this module's Localizable.xcstrings).
struct McpServersStrings {
    static var title: String { text("mcpServers.title", "MCP Servers") }
    static var subtitle: String {
        text("mcpServers.subtitle", "Servers you connected for your agents. Only you can change them here; an agent cannot.")
    }
    static var empty: String {
        text("mcpServers.empty", "No MCP servers yet. When an agent asks to connect one, you approve it in the chat.")
    }
    static var loading: String { text("mcpServers.loading", "Loading…") }
    static var reload: String { text("mcpServers.reload", "Reload") }
    static var viewAudit: String { text("mcpServers.viewAudit", "View Audit Log") }
    static var auditTitle: String { text("mcpServers.auditTitle", "MCP Audit Log") }
    static var auditEmpty: String { text("mcpServers.auditEmpty", "The audit log is empty.") }
    static var auditNote: String {
        text("mcpServers.auditNote", "Each line records an add, sign-in, key, policy change, removal or tool call. It keeps digests, never values.")
    }
    static var done: String { text("mcpServers.done", "Done") }
    static var verified: String { text("mcpServers.verified", "Verified") }
    static var unverified: String { text("mcpServers.unverified", "Not verified") }
    static var publisher: String { text("mcpServers.publisher", "Publisher") }
    static var url: String { text("mcpServers.url", "URL") }
    static var scope: String { text("mcpServers.scope", "Available to") }
    static var state: String { text("mcpServers.state", "State") }
    static var tools: String { text("mcpServers.tools", "Tools") }
    static var noTools: String { text("mcpServers.noTools", "No approved tools.") }
    static var remove: String { text("mcpServers.remove", "Remove") }
    static var removeConfirm: String {
        text("mcpServers.removeConfirm", "Remove this server? Agents lose its tools, and cmux deletes its key or sign-in.")
    }
    static var cancel: String { text("mcpServers.cancel", "Cancel") }
    static var signIn: String { text("mcpServers.signIn", "Sign In…") }
    static var signInAgain: String { text("mcpServers.signInAgain", "Sign In Again…") }
    static var keyPlaceholder: String { text("mcpServers.keyPlaceholder", "Key") }
    static var saveKey: String { text("mcpServers.saveKey", "Save Key") }
    static var replaceKey: String { text("mcpServers.replaceKey", "Replace Key") }
    static var keyPrivate: String { text("mcpServers.keyPrivate", "Only cmux sees this key. Agents never do.") }
    static var heldTitle: String { text("mcpServers.held.title", "Changed tools wait for your approval") }
    static var heldNote: String {
        text("mcpServers.held.note", "These tools are new or changed since you approved this server. Agents cannot see or call them until you approve them.")
    }
    static var heldBadge: String { text("mcpServers.held.badge", "Held") }
    static var approveTools: String { text("mcpServers.approveTools", "Approve Changed Tools") }
    static var noWindow: String { text("mcpServers.noWindow", "Open a cmux window first.") }
    static func unknownReference(_ name: String) -> String {
        String(format: text("mcpServers.unknownReference", "No MCP server is named %@."), name)
    }

    static func policy(_ policy: McpToolPolicy) -> String {
        switch policy {
        case .always: text("mcpServers.policy.always", "Always allow")
        case .ask: text("mcpServers.policy.ask", "Ask each time")
        case .never: text("mcpServers.policy.never", "Never allow")
        }
    }

    static func scope(_ scope: String) -> String {
        switch scope {
        case "chat": text("mcpServers.scope.chat", "This chat")
        case "chief": text("mcpServers.scope.chief", "This Chief and its agents")
        case "allChiefs": text("mcpServers.scope.allChiefs", "All Chiefs")
        case "agents": text("mcpServers.scope.agents", "All agents")
        case "everywhere": text("mcpServers.scope.everywhere", "Everywhere")
        default: scope
        }
    }

    static func state(_ state: String) -> String {
        switch state {
        case "connected": text("mcpServers.state.connected", "Connected")
        case "needsSignIn": text("mcpServers.state.needsSignIn", "Needs sign-in")
        case "needsKey": text("mcpServers.state.needsKey", "Needs a key")
        case "failed": text("mcpServers.state.failed", "Failed")
        case "revoked": text("mcpServers.state.revoked", "Revoked")
        default: state
        }
    }

    static func notice(_ notice: McpServersNotice) -> String {
        switch notice {
        case .unavailable:
            text("mcpServers.notice.unavailable", "cmux could not reach its agent service. Try again in a moment.")
        case .failed: text("mcpServers.notice.failed", "That did not work. The list shows the current state.")
        case .keyRefused: text("mcpServers.notice.keyRefused", "The server did not accept the key. cmux kept nothing.")
        case .keySaved: text("mcpServers.notice.keySaved", "Key saved. The server is connected.")
        case .signInOpened: text("mcpServers.notice.signInOpened", "Finish signing in on the page that opened.")
        case .removed: text("mcpServers.notice.removed", "Server removed.")
        case .toolsApproved: text("mcpServers.notice.toolsApproved", "Changed tools approved. Agents can use them now.")
        }
    }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
