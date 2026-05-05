import Foundation

extension SessionAgent {
    var displayName: String {
        switch self {
        case .claude: return String(localized: "sessionIndex.agent.claude", defaultValue: "Claude Code")
        case .codex: return String(localized: "sessionIndex.agent.codex", defaultValue: "Codex")
        case .opencode: return String(localized: "sessionIndex.agent.opencode", defaultValue: "OpenCode")
        case .rovodev: return String(localized: "sessionIndex.agent.rovodev", defaultValue: "Rovo Dev")
        case .registered(let id):
            if let name = CmuxVaultAgentDisplayNameCache.name(for: id) {
                return name
            } else if id == "pi" {
                return String(localized: "sessionIndex.agent.pi", defaultValue: "Pi")
            }
            return id
        }
    }

    /// Asset catalog image name for the agent's brand mark.
    var assetName: String {
        switch self {
        case .claude: return "AgentIcons/Claude"
        case .codex: return "AgentIcons/Codex"
        case .opencode: return "AgentIcons/OpenCode"
        case .rovodev: return "AgentIcons/RovoDev"
        case .registered:
            return "AgentIcons/OpenCode"
        }
    }
}

enum CmuxVaultAgentDisplayNameCache {
    private static let lock = NSLock()
    private static var namesByID: [String: String] = [:]

    static func store(registrations: [CmuxVaultAgentRegistration]) {
        lock.lock()
        for registration in registrations {
            if registration.id == "pi", registration.name == "Pi" {
                continue
            }
            namesByID[registration.id] = registration.name
        }
        lock.unlock()
    }

    static func name(for id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return namesByID[id]
    }
}
