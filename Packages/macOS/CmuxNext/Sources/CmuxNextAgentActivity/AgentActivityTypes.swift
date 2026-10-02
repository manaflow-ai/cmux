public import Foundation

// Projection types of the CUA host's records (plans/cmux-next/computer-use.md
// sections 3 and 4). The CUA host owns every value here; this module only
// renders them and sends user operations back through `AgentActivitySource`.

/// How the host learned which agent drives a session, strongest first.
public nonisolated enum AgentActivityAttribution: String, Sendable, Hashable {
    case credential
    case processTree = "process_tree"
    case none
}

/// Why a session ended.
public nonisolated enum AgentActivityEndReason: String, Sendable, Hashable {
    case agentEnd = "agent_end"
    case idleTTL = "idle_ttl"
    case userStop = "user_stop"
    case hostRestart = "host_restart"
    case policy
}

public nonisolated enum AgentActivityStatus: Sendable, Hashable {
    case active
    case idle
    case paused
    case ended(AgentActivityEndReason)

    public var isLive: Bool {
        if case .ended = self { return false }
        return true
    }
}

/// One `cua_session` record as the pane shows it.
public nonisolated struct AgentActivitySession: Sendable, Hashable, Identifiable {
    public let id: String
    /// Machine id; sessions are grouped by it.
    public var machine: String
    /// Display name of the machine ("This Mac", a mini's name, a VM's name).
    public var machineName: String
    /// The caller's free-form session string.
    public var label: String
    /// `claude`, `codex`, `acp:<harness>`, `mux`, `cli`, ...
    public var agentKind: String
    /// Human name of the agent ("Claude Code", "Codex", a mux's name).
    public var agentName: String
    public var attribution: AgentActivityAttribution
    public var workspaceTitle: String?
    public var terminalTitle: String?
    /// Cursor color of the session, `#RRGGBB`.
    public var colorHex: String
    public var targetApps: [String]
    public var status: AgentActivityStatus
    public var startedAt: Date
    public var lastActionAt: Date
    public var endedAt: Date?
    public var acts: Int
    public var observes: Int
    public var errors: Int
    /// Input goes to a foreground window only (a user's Wayland desktop).
    public var foregroundOnly: Bool

    public init(
        id: String, machine: String, machineName: String, label: String, agentKind: String, agentName: String,
        attribution: AgentActivityAttribution, workspaceTitle: String? = nil, terminalTitle: String? = nil,
        colorHex: String, targetApps: [String] = [], status: AgentActivityStatus, startedAt: Date,
        lastActionAt: Date, endedAt: Date? = nil, acts: Int = 0, observes: Int = 0, errors: Int = 0,
        foregroundOnly: Bool = false
    ) {
        self.id = id
        self.machine = machine
        self.machineName = machineName
        self.label = label
        self.agentKind = agentKind
        self.agentName = agentName
        self.attribution = attribution
        self.workspaceTitle = workspaceTitle
        self.terminalTitle = terminalTitle
        self.colorHex = colorHex
        self.targetApps = targetApps
        self.status = status
        self.startedAt = startedAt
        self.lastActionAt = lastActionAt
        self.endedAt = endedAt
        self.acts = acts
        self.observes = observes
        self.errors = errors
        self.foregroundOnly = foregroundOnly
    }
}

public nonisolated enum AgentActivityEventKind: String, Sendable, Hashable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case sessionStop = "session_stop"
    case sessionPause = "session_pause"
    case sessionResume = "session_resume"
    case sessionIdle = "session_idle"
    case observe
    case act
    case policyReject = "policy_reject"
    case consentRequest = "consent_request"
    case consentDecide = "consent_decide"
    case error
}

/// A stored frame: an event's before or after image.
public nonisolated struct AgentActivityFrameRef: Sendable, Hashable {
    public let blob: String
    public let width: Int
    public let height: Int
    /// Retention removed the pixels; the event stays.
    public var expired: Bool

    public init(blob: String, width: Int, height: Int, expired: Bool = false) {
        self.blob = blob
        self.width = width
        self.height = height
        self.expired = expired
    }
}

/// One row of a session's event log.
public nonisolated struct AgentActivityEvent: Sendable, Hashable, Identifiable {
    public var id: UInt64 { seq }
    public let seq: UInt64
    public let time: Date
    public let kind: AgentActivityEventKind
    /// Tool name as the agent called it (`click`, `type_text`, ...).
    public let tool: String?
    /// App and window title, already redacted by the host.
    public let target: String?
    public let ok: Bool
    public let errorCode: String?
    public let durationMs: Int?
    /// Typed text the host replaced by its length (C5).
    public let redactedTextLength: Int?
    public let beforeFrame: AgentActivityFrameRef?
    public let afterFrame: AgentActivityFrameRef?
    /// Click position as a fraction of the frame (0...1, top-left origin).
    public let clickPoint: CGPoint?

    public init(
        seq: UInt64, time: Date, kind: AgentActivityEventKind, tool: String? = nil, target: String? = nil,
        ok: Bool = true, errorCode: String? = nil, durationMs: Int? = nil, redactedTextLength: Int? = nil,
        beforeFrame: AgentActivityFrameRef? = nil, afterFrame: AgentActivityFrameRef? = nil, clickPoint: CGPoint? = nil
    ) {
        self.seq = seq
        self.time = time
        self.kind = kind
        self.tool = tool
        self.target = target
        self.ok = ok
        self.errorCode = errorCode
        self.durationMs = durationMs
        self.redactedTextLength = redactedTextLength
        self.beforeFrame = beforeFrame
        self.afterFrame = afterFrame
        self.clickPoint = clickPoint
    }

    /// The frame the timeline shows for this event (after, else before).
    public var displayFrame: AgentActivityFrameRef? { afterFrame ?? beforeFrame }
}

/// User operations the pane sends to the owning CUA host. The host decides;
/// the pane changes nothing until the host's update arrives.
public nonisolated enum AgentActivityUserOp: Sendable, Hashable {
    case stop(session: String)
    case pause(session: String)
    case resume(session: String)
    case watch(session: String, on: Bool)
    case export(session: String)
    case openAgent(session: String)
    case openTarget(session: String)
    case stopAll(machine: String)
}

/// Connection to one machine's CUA host.
public nonisolated enum AgentActivityConnection: Sendable, Hashable {
    case connected
    /// Computer use has not run on the machine yet (no host socket).
    case notStarted
    /// Accessibility or Screen Recording is missing for the helper.
    case notSetUp
    case unreachable
}

/// What a source pushes to the model.
public nonisolated enum AgentActivityUpdate: Sendable {
    /// The full current list of sessions of `machine` (replaces the last one).
    case sessions(machine: String, [AgentActivitySession])
    /// New events of one session, in seq order, starting at the next seq.
    case events(session: String, [AgentActivityEvent])
    case connection(machine: String, AgentActivityConnection)
}
