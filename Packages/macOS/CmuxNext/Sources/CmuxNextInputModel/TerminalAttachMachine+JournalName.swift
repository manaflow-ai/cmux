extension TerminalAttachMachine.Phase {
    /// Stable phase name for the input journal and replay (the journal's
    /// attach records and `InputReplay` compare these strings).
    package nonisolated var journalName: String {
        switch self {
        case .detached: "detached"
        case .attaching(let pending): pending.link == nil ? "attaching" : "attaching:linked"
        case .live: "live"
        case .reattaching(let pending): pending.link == nil ? "reattaching" : "reattaching:linked"
        case .disconnected(let disconnected): "disconnected:\(disconnected.reason)"
        case .exited: "exited"
        case .closed: "closed"
        }
    }
}
