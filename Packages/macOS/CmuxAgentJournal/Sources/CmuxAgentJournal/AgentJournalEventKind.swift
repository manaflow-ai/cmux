/// The semantic agent-event taxonomy recorded in the agent journal.
///
/// This is a port of the cmux-tui session journal's 12 `agent.*` event kinds
/// (`cmux-tui/crates/cmux-tui-core/src/agent_hooks.rs`), so the macOS journal
/// and the Rust journal describe agent activity in the same vocabulary. Sidebar
/// lifecycle state is a deterministic fold over a stream of these kinds — never
/// a substring classification of prose.
public enum AgentJournalEventKind: String, Codable, Sendable, CaseIterable, Equatable {
    /// An agent process booted or reset a session.
    case sessionStarted = "agent.session.started"
    /// A user prompt was submitted / the agent began working on a turn.
    case turnStarted = "agent.turn.started"
    /// The agent settled: the turn is over (unless `pendingWork` is set).
    case turnCompleted = "agent.turn.completed"
    /// A subagent was spawned by the session.
    case childSpawned = "agent.child.spawned"
    /// A subagent finished.
    case childCompleted = "agent.child.completed"
    /// A subagent failed.
    case childFailed = "agent.child.failed"
    /// The agent is blocked on a tool/permission approval.
    case approvalRequested = "agent.approval.requested"
    /// The agent asked the user a question and is waiting for the answer.
    case questionRequested = "agent.question.requested"
    /// The agent presented a plan for review and is waiting for approval.
    case planReviewRequested = "agent.plan_review.requested"
    /// The agent reported an error (stop failure, tool failure, on_error).
    case errorReported = "agent.error.reported"
    /// Catch-all for native events with no stronger semantic mapping. Only
    /// reduces to a lifecycle phase when the event declares one explicitly.
    case stateChanged = "agent.state.changed"
    /// The session ended (teardown, replacement, or finalize).
    case sessionEnded = "agent.session.ended"
}
