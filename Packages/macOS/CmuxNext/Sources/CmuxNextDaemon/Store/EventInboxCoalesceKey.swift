import CmuxNextWakeups

/// The events ``EventInbox`` coalesces: each states the whole current value of one field of one
/// surface, and the store applies it as a plain write, so only the newest in a batch matters.
///
/// `agent-changed` is not one of them: the roster records the transition from the old status to
/// the new one (``AgentRoster/startsPromptedTurn(from:to:)``, ``AgentTimeline/events(from:to:nowMs:)``),
/// so a working -> idle -> working run collapsed to its last status would lose a finished turn and
/// a prompt.
enum CoalesceKey: Hashable {
    case title(SurfaceID)
    case size(SurfaceID)
    case scroll(SurfaceID)
    case presence(SurfaceID)

    init?(_ event: DaemonEvent) {
        switch event {
        case .titleChanged(let surface, _): self = .title(surface)
        case .surfaceResized(let surface, _): self = .size(surface)
        case .scrollChanged(let surface, _, _): self = .scroll(surface)
        case .agentPresenceChanged(let presence): self = .presence(presence.surface)
        default: return nil
        }
    }
}

/// What joins an event to the one before it in one daemon transaction, which the drain never splits
/// across tasks or frames (p06-scheduler-223, ``DrainTail``): close twelve panes and their layout
/// change never show half applied. The daemon emits a request's events in a row.
enum TransactionKey: Equatable {
    /// The echo of one client request: every event that names the request's `transaction`.
    case client(ClientTransactionID)
    /// A tree change no client tagged, with its cause. Nothing on the wire tells one untagged
    /// request's events from the next one's, so adjacent ones of one cause apply together.
    case untagged(ObservationCause)

    /// nil: the event is a transaction by itself (a whole-value field, an agent status, a side event).
    init?(_ envelope: DaemonEventEnvelope) {
        if let transaction = envelope.event.clientTransactionID {
            self = .client(transaction)
            return
        }
        switch envelope.event {
        case .workspaceAdded, .workspaceClosed, .workspaceRenamed, .workspaceMoved, .workspaceChanged,
             .screenAdded, .screenClosed, .screenRenamed, .screenChanged, .paneAdded, .paneClosed,
             .tabAdded, .tabClosed, .tabRenamed, .tabChanged, .layoutChanged, .treeChanged:
            self = .untagged(envelope.cause)
        default:
            return nil
        }
    }
}

extension DaemonEvent {
    /// A connection change or an event that asks for a snapshot: the drain applies it in its frame
    /// (p06-scheduler-223), as it does the snapshot that follows; the drain's tail never holds it.
    var drainsInFrame: Bool {
        switch self {
        case .connected, .disconnected, .daemonShutdown, .overflow, .treeChanged, .layoutChanged(_, .none, _): true
        default: false
        }
    }
}
