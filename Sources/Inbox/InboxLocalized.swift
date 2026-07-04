import CMUXAgentLaunch
import CmuxInbox
import Foundation

enum InboxLocalized {
    static func sourceLabel(_ source: InboxSource?) -> String {
        guard let source else {
            return String(localized: "inbox.source.all", defaultValue: "All")
        }
        switch source {
        case .agent:
            return String(localized: "inbox.source.agents", defaultValue: "Agents")
        case .gmail:
            return String(localized: "inbox.source.gmail", defaultValue: "Gmail")
        case .slack:
            return String(localized: "inbox.source.slack", defaultValue: "Slack")
        case .discord:
            return String(localized: "inbox.source.discord", defaultValue: "Discord")
        case .imessage:
            return String(localized: "inbox.source.imessage", defaultValue: "iMessage")
        case .generic:
            return String(localized: "inbox.source.generic", defaultValue: "Generic")
        }
    }

    static func filterLabel(_ filter: InboxListFilter) -> String {
        switch filter {
        case .actionable:
            return String(localized: "inbox.filter.actionable", defaultValue: "Actionable")
        case .unread:
            return String(localized: "inbox.filter.unread", defaultValue: "Unread")
        case .all:
            return String(localized: "inbox.filter.all", defaultValue: "All")
        }
    }

    static func statusLabel(_ status: InboxAccountStatus) -> String {
        switch status {
        case .disconnected:
            return String(localized: "inbox.status.disconnected", defaultValue: "Disconnected")
        case .connected:
            return String(localized: "inbox.status.connected", defaultValue: "Connected")
        case .syncing:
            return String(localized: "inbox.status.syncing", defaultValue: "Syncing")
        case .degraded:
            return String(localized: "inbox.status.degraded", defaultValue: "Needs attention")
        case .missingCredentials:
            return String(localized: "inbox.status.missingCredentials", defaultValue: "Needs credentials")
        case .missingHelper:
            return String(localized: "inbox.status.missingHelper", defaultValue: "Helper missing")
        case .permissionDenied:
            return String(localized: "inbox.status.permissionDenied", defaultValue: "Permission denied")
        case .rateLimited:
            return String(localized: "inbox.status.rateLimited", defaultValue: "Rate limited")
        case .tokenExpired:
            return String(localized: "inbox.status.tokenExpired", defaultValue: "Token expired")
        case .error:
            return String(localized: "inbox.status.error", defaultValue: "Error")
        }
    }

    static func capabilityLabel(_ capability: InboxConnectorCapability) -> String {
        switch capability {
        case .liveEvents:
            return String(localized: "inbox.capability.liveEvents", defaultValue: "Live events")
        case .backfill:
            return String(localized: "inbox.capability.backfill", defaultValue: "Backfill")
        case .markRead:
            return String(localized: "inbox.capability.markRead", defaultValue: "Mark read")
        case .sendReply:
            return String(localized: "inbox.capability.sendReply", defaultValue: "Approved replies")
        case .deepLink:
            return String(localized: "inbox.capability.deepLink", defaultValue: "Open original")
        }
    }

    static func agentSourceLabel(_ source: WorkstreamSource) -> String {
        switch source {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .pi: return "Pi"
        case .amp: return "Amp"
        case .cursor: return "Cursor"
        case .opencode: return "OpenCode"
        case .gemini: return "Gemini"
        case .hermesAgent: return "Hermes Agent"
        case .copilot: return "Copilot"
        case .codebuddy: return "CodeBuddy"
        case .factory: return "Factory"
        case .qoder: return "Qoder"
        }
    }
}
