/// What a docked column is for (daemon `dock.role`, `dock-column-role-v1`).
public nonisolated enum DockRole: String, Hashable, Sendable {
    /// The agent chat column: new terminals and browsers open beside it,
    /// never in it (lawrence-call-1006 D).
    case agentChat
}
