extension TerminalPromptInputLedger {
    /// Admission-time identity for human input in one agent-composer epoch.
    ///
    /// A snapshot can safely cross a cold-surface queue. Confirmations from a
    /// previous scope are ignored even when their generation happens to match
    /// the current scope.
    public struct HumanInputSnapshot: Sendable, Equatable {
        let epoch: UInt64
        let generation: UInt64
    }
}
