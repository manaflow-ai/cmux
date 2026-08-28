import Foundation

extension CloudAgentSkillLauncher {
    /// Agents the launcher can start locally. Raw values are the executable
    /// names resolved through the user's login shell PATH, and are also the
    /// `agent` parameter accepted by `vm.cloud_agent_open`.
    enum CodingAgent: String, CaseIterable {
        case claude
        case codex
        case opencode

        var displayName: String {
            switch self {
            case .claude:
                return String(localized: "machines.agent.claude", defaultValue: "Claude Code")
            case .codex:
                return String(localized: "machines.agent.codex", defaultValue: "Codex")
            case .opencode:
                return String(localized: "machines.agent.opencode", defaultValue: "OpenCode")
            }
        }

        /// Interactive-session argv carrying the kickoff prompt. claude and
        /// codex take a positional initial prompt; opencode uses `--prompt`.
        /// Elements are argv words; the local provider shell-quotes them.
        func argv(prompt: String) -> [String] {
            switch self {
            case .claude: return ["claude", prompt]
            case .codex: return ["codex", prompt]
            case .opencode: return ["opencode", "--prompt", prompt]
            }
        }
    }
}
