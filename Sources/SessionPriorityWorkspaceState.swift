import CMUXAgentLaunch
import Foundation
import Observation

/// Where a workspace's effective Claude difficulty came from. A plain value the plan, the
/// snapshot and the status row carry across actors, so it lives outside the main-actor
/// ``SessionPriorityWorkspaceState`` and has no actor isolation of its own.
enum SessionPriorityDifficultySource: String, Sendable {
    case override, auto, `default`
}

/// The workspace-owned session priority inputs: the Claude task difficulty
/// (a manual override, else an auto value from a turn-end assessment) and the
/// "don't adjust this workspace" flag. An `@Observable` model held as a `let` on
/// `Workspace`. Mutation goes through `Workspace+SessionPriority.swift`, which
/// also sends the sidebar row its change event
/// (`Workspace.sessionPriorityDidChangeSubject`); this model publishes nothing
/// through Combine.
@MainActor
@Observable
final class SessionPriorityWorkspaceState {
    /// The user's difficulty choice; never expires, `nil` means automatic.
    var difficultyOverride: ClaudeSessionDifficulty? = nil
    /// The difficulty assessed at the last turn end, or `nil` before any.
    var autoDifficulty: ClaudeSessionDifficulty? = nil
    /// When true, the coordinator leaves this workspace's effort alone.
    var isManual = false

    /// The override, else the auto value, else `.normal`.
    var effectiveDifficulty: ClaudeSessionDifficulty {
        difficultyOverride ?? autoDifficulty ?? .normal
    }

    var difficultySource: SessionPriorityDifficultySource {
        if difficultyOverride != nil { return .override }
        if autoDifficulty != nil { return .auto }
        return .default
    }
}
