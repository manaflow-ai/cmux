/// Searches the agent memory index that the user's Codex and Claude Code sessions share.
public nonisolated protocol AgentMemoryIndex: Sendable {
    /// Entries holding every word of `query`, best first.
    /// - Parameters:
    ///   - query: The words to find, passed as written.
    ///   - limit: The most hits to return.
    /// - Returns: The index's hits.
    /// - Throws: `operation.unsupported` when this build has no index tool, else `memory.unavailable`.
    func search(query: String, limit: Int) async throws(AppHostCapabilityError) -> [AgentMemoryHit]
}
