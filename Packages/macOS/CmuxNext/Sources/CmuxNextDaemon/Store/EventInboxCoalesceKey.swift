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

/// One daemon transaction as the drain cuts a batch (``DrainTail``), which it never
/// splits across tasks or frames: close twelve panes and their layout change never show half applied.
/// The daemon emits a request's events in a row but tags only some of them with the client's
/// `transaction` (a browser create's `screen-added` and `layout-changed` go untagged, its `tab-added`
/// tagged), and nothing marks where one untagged request ends. So a run joins the tree events of one
/// cause that carry at most one tag, and caps each stretch of untagged ones at ``untaggedLimit``: a
/// storm of untagged CLI or agent requests still spreads over tasks.
struct TransactionRun {
    /// The most untagged events a run takes in a row.
    static let untaggedLimit = 32

    private let cause: ObservationCause
    private var tag: ClientTransactionID?
    /// Untagged events since the run's last tagged one.
    private var untagged: Int

    /// Starts a run at `envelope`; nil: the event is a transaction by itself (a whole-value field, an
    /// agent status, a side event).
    init?(_ envelope: DaemonEventEnvelope) {
        let tag = envelope.event.clientTransactionID
        guard tag != nil || envelope.event.isTreeChange else { return nil }
        cause = envelope.cause
        self.tag = tag
        untagged = tag == nil ? 1 : 0
    }

    /// Adds `envelope` to the run; false: it starts the next transaction.
    mutating func join(_ envelope: DaemonEventEnvelope) -> Bool {
        guard envelope.cause == cause else { return false }
        if let next = envelope.event.clientTransactionID {
            guard tag == nil || tag == next else { return false }
            tag = next
            untagged = 0
            return true
        }
        guard envelope.event.isTreeChange, untagged < Self.untaggedLimit else { return false }
        untagged += 1
        return true
    }
}

extension DaemonEvent {
    /// A connection change or an event that asks for a snapshot: the drain applies it in its frame,
    /// as it does the snapshot that follows; the drain's tail never holds it.
    var drainsInFrame: Bool {
        switch self {
        case .connected, .disconnected, .daemonShutdown, .overflow, .treeChanged, .layoutChanged(_, .none, _): true
        default: false
        }
    }

    /// A workspace, screen, pane, tab or layout change: part of a request's tree echo.
    var isTreeChange: Bool {
        switch self {
        case .workspaceAdded, .workspaceClosed, .workspaceRenamed, .workspaceMoved, .workspaceChanged,
             .screenAdded, .screenClosed, .screenRenamed, .screenChanged, .paneAdded, .paneClosed,
             .tabAdded, .tabClosed, .tabRenamed, .tabChanged, .layoutChanged, .treeChanged: true
        default: false
        }
    }
}
