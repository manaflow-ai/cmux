/// The source-qualified automatic-team binding for one task-sync hook.
public struct ClaudeTeamTaskListResolution: Equatable, Sendable {
    /// The exact team identity and canonical shared task list.
    public let binding: ClaudeTeamTaskListBinding
    /// Whether the config disappeared and this hook is using retained proof.
    ///
    /// Callers may use this proof to deliver the final empty reconciliation,
    /// but must not refresh it as though a live team config confirmed it.
    public let usesRetainedCleanupProof: Bool

    /// Creates a source-qualified resolution inside ``CMUXAgentLaunch``.
    init(binding: ClaudeTeamTaskListBinding, usesRetainedCleanupProof: Bool) {
        self.binding = binding
        self.usesRetainedCleanupProof = usesRetainedCleanupProof
    }
}
