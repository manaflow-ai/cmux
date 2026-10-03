import Foundation

/// A coding agent whose session files name the folders it worked in.
public nonisolated enum AgentApp: String, CaseIterable, Sendable, Comparable {
    case claudeCode, codex, pi, opencode

    /// The product's own name (not translated).
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .pi: "Pi"
        case .opencode: "OpenCode"
        }
    }

    public static func < (lhs: AgentApp, rhs: AgentApp) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
