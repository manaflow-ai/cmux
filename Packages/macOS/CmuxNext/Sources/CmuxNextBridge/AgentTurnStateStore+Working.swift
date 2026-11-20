extension AgentTurnStateStore {
    /// Some session of this Mac's acpmux (or a mirrored one on this Mac) runs a prompt turn, whether or not
    /// a tab shows it (`sessions.keepAwake`). An acpmux peer's row never counts: another machine's agent keeps
    /// that machine awake, and its chats catch up from one list read when this Mac wakes. Leo, 2026-11-18, to
    /// "stay awake for local agents, and ignore other machines'": "Yeah sure". One read of the working count
    /// (``workingSessions``): an observer re-evaluates only when the count changes, never on a walk of every record.
    public var hasWorkingSession: Bool { workingSessions > 0 }
}
