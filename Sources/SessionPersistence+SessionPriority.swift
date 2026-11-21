import CMUXAgentLaunch
import Foundation

extension SessionWorkspaceSnapshot {
    /// Captures the live difficulty and manual flag; default values write no fields.
    @MainActor
    mutating func captureSessionPriorityState(from workspace: Workspace) {
        let state = workspace.sessionPriorityState
        claudeDifficultyOverride = state.difficultyOverride?.rawValue
        claudeDifficultyAuto = state.autoDifficulty?.rawValue
        sessionPriorityManual = state.isManual ? true : nil
    }

    /// The decoded override, or `nil` when absent or unknown.
    var restoredClaudeDifficultyOverride: ClaudeSessionDifficulty? {
        claudeDifficultyOverride.flatMap(ClaudeSessionDifficulty.init(rawValue:))
    }

    /// The decoded auto difficulty, or `nil` when absent or unknown.
    var restoredClaudeDifficultyAuto: ClaudeSessionDifficulty? {
        claudeDifficultyAuto.flatMap(ClaudeSessionDifficulty.init(rawValue:))
    }
}
