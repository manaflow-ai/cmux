import Foundation

extension SessionAgent {
    var displayName: String {
        switch self {
        case .claude: return String(localized: "sessionIndex.agent.claude", defaultValue: "Claude Code")
        case .codex: return String(localized: "sessionIndex.agent.codex", defaultValue: "Codex")
        case .opencode: return String(localized: "sessionIndex.agent.opencode", defaultValue: "OpenCode")
        case .rovodev: return String(localized: "sessionIndex.agent.rovodev", defaultValue: "Rovo Dev")
        }
    }

    /// Asset catalog image name for the agent's brand mark.
    var assetName: String {
        switch self {
        case .claude: return "AgentIcons/Claude"
        case .codex: return "AgentIcons/Codex"
        case .opencode: return "AgentIcons/OpenCode"
        case .rovodev: return "AgentIcons/RovoDev"
        }
    }
}
