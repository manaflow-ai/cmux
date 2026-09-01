/// The single action selected for one proven turn boundary.
public enum AgentStallSupervisorDecision: Equatable, Sendable {
    /// Retry the same managed session after a bounded delay.
    case retry(attempt: Int, maximumAttempts: Int, delaySeconds: Int, actionID: String)
    /// Notify a person and leave the session untouched.
    case notify(cause: AgentStallCause, suggestedActionID: String)
    /// Ignore the observation and perform no user-visible action.
    case ignore(AgentStallSupervisorRejection)
}
