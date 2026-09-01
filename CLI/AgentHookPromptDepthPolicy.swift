import Foundation

/// Describes how an agent's lifecycle hooks represent active prompt work.
///
/// Most adapters emit one prompt-start callback for each nested turn and use a
/// balanced counter. Adapters whose prompt-start callback repeats while one
/// execution loop is active use the authoritative policy: starts are
/// idempotent and a completion boundary closes the whole loop.
enum AgentHookPromptDepthPolicy: Sendable {
    case balanced
    case authoritative

    var closesActivePrompt: Bool {
        switch self {
        case .balanced: false
        case .authoritative: true
        }
    }
}

extension ClaudeHookSessionRecord {
    mutating func beginAuthoritativePrompt(turnId: String?) {
        activePromptDepth = 1
        activePromptTurnId = turnId
        activePromptTurnIds = turnId.map { [$0] }
        lastPromptTurnId = turnId
    }

    mutating func endAuthoritativePrompt() {
        activePromptDepth = nil
        activePromptTurnId = nil
        activePromptTurnIds = nil
    }

    mutating func clearPromptStartState() {
        endAuthoritativePrompt()
        lastPromptTurnId = nil
    }
}

extension CMUXCLI.AgentHookDef {
    /// Per-turn session boundaries imply authoritative prompt-depth recovery.
    var promptDepthPolicy: AgentHookPromptDepthPolicy {
        sessionEndIsTurnBoundary ? .authoritative : .balanced
    }
}
