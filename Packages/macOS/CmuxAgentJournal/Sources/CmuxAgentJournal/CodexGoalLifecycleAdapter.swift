/// Maps Codex objective notifications into the provider-neutral lifecycle.
public struct CodexGoalLifecycleAdapter: Sendable {
    /// Creates the stateless Codex adapter.
    public init() {}

    /// Converts a Codex thread goal status into a fail-closed lifecycle state.
    ///
    /// - Parameter notificationValue: The status string from
    ///   `ThreadGoalUpdatedNotification` or a usage-limit notification.
    /// - Returns: The corresponding objective state.
    public func state(for notificationValue: String) -> AgentGoalLifecycleState {
        AgentGoalLifecycleState.fromProviderValue(notificationValue)
    }
}
