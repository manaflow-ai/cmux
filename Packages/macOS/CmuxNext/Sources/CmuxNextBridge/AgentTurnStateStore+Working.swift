extension AgentTurnStateStore {
    /// Some acpmux session of this Mac runs a prompt turn, whether or not a tab shows
    /// it (`sessions.keepAwake`). An observer re-evaluates on every turn state
    /// change (`stateRevision`).
    ///
    /// Another machine's chat does not count: sleeping here does not stop it, and its chat catches
    /// up when the Mac wakes. This Mac's acpmux lists its peers' sessions too, and a peer's
    /// summary writes the record's state with that peer's row, so a working state that some peer
    /// row also says is that peer's (Leo, 2026-11-18: "stay awake for local agents, and ignore
    /// other machines'"). Only a local session sharing its id with a working peer session is
    /// missed, and session ids are each daemon's own.
    public var hasWorkingSession: Bool {
        _ = stateRevision
        return sessions.values.contains { record in
            record.state == .working && !record.peers.values.contains { $0.state == .working }
        }
    }
}
