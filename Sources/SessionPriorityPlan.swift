import CMUXAgentLaunch
import Foundation

/// Which tier and target each Claude workspace of one window gets.
///
/// Only workspaces with a Claude pane take part. The first `urgentCount` of them in the
/// window's effective rank order are urgent; the rest are slow.
enum SessionPriorityPlan {
    /// What the plan needs to know about one workspace.
    struct WorkspaceInput: Equatable {
        var id: UUID
        var hasClaudePane: Bool
        var difficulty: ClaudeSessionDifficulty
        var difficultySource: SessionPriorityWorkspaceState.DifficultySource
        /// The user asked cmux to leave this workspace's effort alone.
        var isManual: Bool
    }

    /// One workspace's tier and what to apply to it.
    struct Entry: Equatable {
        var workspaceId: UUID
        var tier: SessionPriorityTier
        var difficulty: ClaudeSessionDifficulty
        var difficultySource: SessionPriorityWorkspaceState.DifficultySource
        /// `nil` for a manual workspace; it keeps its slot but gets nothing applied.
        var target: SessionPriorityTarget?
    }

    /// Entries by workspace id. A negative `urgentCount` counts as zero.
    static func make(
        effectiveOrder: [UUID],
        workspaces: [UUID: WorkspaceInput],
        urgentCount: Int,
        matrix: SessionPriorityMatrix
    ) -> [UUID: Entry] {
        var entries: [UUID: Entry] = [:]
        var slots = max(urgentCount, 0)
        for id in effectiveOrder {
            guard entries[id] == nil, let input = workspaces[id], input.hasClaudePane else { continue }
            let tier: SessionPriorityTier = slots > 0 ? .urgent : .slow
            if slots > 0 { slots -= 1 }
            entries[id] = Entry(
                workspaceId: id,
                tier: tier,
                difficulty: input.difficulty,
                difficultySource: input.difficultySource,
                target: input.isManual ? nil : matrix.target(tier: tier, difficulty: input.difficulty)
            )
        }
        return entries
    }
}
