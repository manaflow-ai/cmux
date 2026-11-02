import CMUXAgentLaunch
import Combine
import Foundation

/// Where a workspace's effective Claude difficulty came from. A plain value the plan, the
/// snapshot and the status row carry across actors, so it lives outside the main-actor
/// ``SessionPriorityWorkspaceState`` and has no actor isolation of its own.
enum SessionPriorityDifficultySource: String, Sendable {
    case override, auto, `default`
}

/// The workspace-owned session priority inputs: the Claude task difficulty
/// (a manual override, else an auto value from a turn-end assessment) and the
/// "don't adjust this workspace" flag. A separate `ObservableObject` held as a
/// `let` on `Workspace`, like `WorkspaceTodoState`, so changes publish through
/// their own object. Mutation goes through `Workspace+SessionPriority.swift`.
@MainActor
final class SessionPriorityWorkspaceState: ObservableObject {
    /// The user's difficulty choice; never expires, `nil` means automatic.
    @Published var difficultyOverride: ClaudeSessionDifficulty?
    /// The difficulty assessed at the last turn end, or `nil` before any.
    @Published var autoDifficulty: ClaudeSessionDifficulty?
    /// When true, the coordinator leaves this workspace's effort alone.
    @Published var isManual: Bool = false

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
