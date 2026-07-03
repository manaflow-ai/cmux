extension CodexTeamsApprovalBridge {
    /// The spawning thread id and the newly spawned child thread ids carried by
    /// a Codex app-server `spawnAgent` collab-agent tool call.
    struct CodexTeamsSpawnedSubagents: Equatable {
        let parentThreadId: String
        let childThreadIds: [String]
    }
}
