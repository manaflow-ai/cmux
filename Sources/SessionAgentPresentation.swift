import Foundation

extension SessionAgent {
    var displayName: String {
        switch self {
        case .claude: return String(localized: "sessionIndex.agent.claude", defaultValue: "Claude Code")
        case .codex: return String(localized: "sessionIndex.agent.codex", defaultValue: "Codex")
        case .grok: return String(localized: "sessionIndex.agent.grok", defaultValue: "Grok")
        case .opencode: return String(localized: "sessionIndex.agent.opencode", defaultValue: "OpenCode")
        case .rovodev: return String(localized: "sessionIndex.agent.rovodev", defaultValue: "Rovo Dev")
        case .registered(let agent):
            return agent.displayName
        case .hermesAgent: return String(localized: "sessionIndex.agent.hermesAgent", defaultValue: "Hermes Agent")
        }
    }

    /// Asset catalog image name for the agent's brand mark.
    var assetName: String? {
        switch self {
        case .claude: return "AgentIcons/Claude"
        case .codex: return "AgentIcons/Codex"
        case .grok: return "AgentIcons/Grok"
        case .opencode: return "AgentIcons/OpenCode"
        case .rovodev: return "AgentIcons/RovoDev"
        case .registered(let agent):
            return agent.iconAssetName
        case .hermesAgent: return "AgentIcons/HermesAgent"
        }
    }

    /// Classifies an agent from free-form name candidates (process names, titles,
    /// labels) by case-insensitive substring match and returns the matched agent's
    /// brand-mark asset name. Candidates are tried in order; the first one whose
    /// lowercased text contains a known agent token wins. Returns `nil` when no
    /// candidate matches.
    static func assetName(forNameCandidates candidates: [String?]) -> String? {
        for candidate in candidates.compactMap({ $0?.lowercased() }) {
            if candidate.contains("opencode") {
                return SessionAgent.opencode.assetName
            }
            if candidate.contains("hermes") {
                return SessionAgent.hermesAgent.assetName
            }
            if candidate.contains("claude") {
                return SessionAgent.claude.assetName
            }
            if candidate.contains("codex") {
                return SessionAgent.codex.assetName
            }
        }
        return nil
    }

    var systemImageName: String? {
        switch self {
        case .registered:
            return assetName == nil ? "person.crop.circle" : nil
        default:
            return nil
        }
    }
}
