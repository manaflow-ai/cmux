extension AgentTurnStateStore {
    /// Some local acpmux session runs a prompt turn, whether or not a tab shows
    /// it (`sessions.keepAwake`). An observer re-evaluates on every turn state
    /// change (`stateRevision`).
    public var hasWorkingSession: Bool {
        _ = stateRevision
        return sessions.values.contains { $0.state == .working }
    }
}
