import Foundation

extension SessionAgent {
    var displayName: String {
        switch self {
        case .claude: return String(localized: "sessionIndex.agent.claude", defaultValue: "Claude Code")
        case .codex: return String(localized: "sessionIndex.agent.codex", defaultValue: "Codex")
        case .opencode: return String(localized: "sessionIndex.agent.opencode", defaultValue: "OpenCode")
        case .rovodev: return String(localized: "sessionIndex.agent.rovodev", defaultValue: "Rovo Dev")
        case .pi: return String(localized: "sessionIndex.agent.pi", defaultValue: "Pi")
        }
    }

    /// Asset catalog image name for the agent's brand mark.
    var assetName: String {
        switch self {
        case .claude: return "AgentIcons/Claude"
        case .codex: return "AgentIcons/Codex"
        case .opencode: return "AgentIcons/OpenCode"
        case .rovodev: return "AgentIcons/RovoDev"
        // TODO: ship AgentIcons/Pi.imageset (placeholder PNGs to be generated
        // by parent agent via PIL). Until the asset lands, NSImage(named:)
        // returns nil and SessionIndexView falls back to its no-icon path.
        case .pi: return "AgentIcons/Pi"
        }
    }
}
