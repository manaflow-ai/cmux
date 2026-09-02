import Foundation

extension ClaudeHookSessionStoreFile {
    /// Durable continuation for one legacy checklist-owner cleanup.
    ///
    /// Workspace IDs remain independent of live session bindings because a
    /// replacement SessionStart can namespace a record before retry runs.
    struct LegacyClaudeTaskOwnerCleanupRecord: Codable, Equatable {
        var workspaceIDs: [String]
        var attemptCount: Int = 0
        var nextAttemptAt: TimeInterval? = nil
    }
}
