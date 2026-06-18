import Foundation

/// The user's decision on a resolved actionable item.
public enum WorkstreamDecision: Codable, Sendable, Equatable {
    case permission(WorkstreamPermissionMode)
    /// `feedback` carries the user's "Tell Claude what to change" text
    /// when non-nil. When present the hook translates into a
    /// `{decision: block, reason: feedback}` response so Claude refines
    /// rather than proceeding.
    case exitPlan(WorkstreamExitPlanMode, feedback: String? = nil)
    case question(selections: [String])
}

/// Lifecycle state of a `WorkstreamItem`.
public enum WorkstreamStatus: Codable, Sendable, Equatable {
    /// Actionable item awaiting user input. Only valid for
    /// `.permissionRequest`, `.exitPlan`, `.question`.
    case pending
    /// Actionable item the user resolved with the given decision.
    case resolved(WorkstreamDecision, at: Date)
    /// Actionable item that timed out before the user acted.
    case expired(at: Date)
    /// Telemetry item (non-actionable). Always starts and stays here.
    case telemetry

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

/// A single feed entry. Workstream IDs group items that belong to the same
/// agent session (e.g. `claude-<sessionId>`, `opencode-<sessionId>`).
public struct WorkstreamItem: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let workstreamId: String
    public let source: WorkstreamSource
    public let kind: WorkstreamKind
    public let createdAt: Date
    public var updatedAt: Date
    public var cwd: String?
    public var title: String?
    public var status: WorkstreamStatus
    public var payload: WorkstreamPayload
    public var context: WorkstreamContext?
    /// PID of the agent process that emitted the event (hook's parent
    /// pid). When non-nil, pending items get expired automatically as
    /// soon as the agent process is gone — a crashed/killed `claude`
    /// or `codex` would otherwise leave orphaned actionable cards
    /// waiting forever. Only the agent PID; not the hook subprocess.
    public var ppid: Int?

    public init(
        id: UUID = UUID(),
        workstreamId: String,
        source: WorkstreamSource,
        kind: WorkstreamKind,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        cwd: String? = nil,
        title: String? = nil,
        status: WorkstreamStatus? = nil,
        payload: WorkstreamPayload,
        context: WorkstreamContext? = nil,
        ppid: Int? = nil
    ) {
        self.id = id
        self.workstreamId = workstreamId
        self.source = source
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.cwd = cwd
        self.title = title
        let resolvedStatus = status ?? (kind.isActionable ? .pending : .telemetry)
        self.status = kind.isActionable ? resolvedStatus : .telemetry
        self.payload = payload
        self.context = context?.isEmpty == true ? nil : context
        self.ppid = ppid
    }
}
