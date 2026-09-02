/// A source-qualified automatic-team binding created inside ``CMUXAgentLaunch``.
public struct ClaudeTeamTaskListResolution: Equatable, Sendable {
    /// The exact team identity and canonical shared task list.
    public let binding: ClaudeTeamTaskListBinding
    /// Whether the config disappeared and this hook is using retained proof.
    ///
    /// Callers may use this proof to deliver the final empty reconciliation,
    /// but must not refresh it as though a live team config confirmed it.
    public let usesRetainedCleanupProof: Bool
}
