import Foundation

/// Reads bounded handoff metadata and contents for context-clear verification.
protocol AgentContextHandoffFileSystem: Sendable {
    /// Opens a path once and returns its descriptor-bound metadata and contents.
    ///
    /// Keeping the metadata and bytes in one operation prevents a replacement
    /// or rename between a pathname metadata lookup and a later reopen from
    /// authorizing a clear for a different file.
    /// - Parameters:
    ///   - path: The local handoff path to inspect.
    ///   - maximumBytes: The hard read limit enforced by the verifier.
    /// - Returns: A descriptor-bound snapshot, or `nil` when no path exists.
    ///   Implementations may read one extra byte beyond `maximumBytes` so the
    ///   verifier can detect growth; callers must treat a returned count above
    ///   the limit as unreadable rather than truncating it.
    func readSnapshot(
        at path: URL,
        maximumBytes: Int
    ) async throws -> AgentContextHandoffFileSnapshot?
}
