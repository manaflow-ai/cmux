import Foundation

extension AgentSessionProviderID {
    /// The acpmux harness family a new chat session starts on.
    var acpmuxHarness: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .opencode: return "opencode"
        }
    }
}
