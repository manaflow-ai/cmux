public import Foundation

/// What a session stores (`SessionRecord.recording`). Thumbnails are the
/// floor; full frames only with `events+frames` or `video`.
public nonisolated enum AgentActivityRecording: String, Sendable, Hashable {
    case events
    case eventsAndFrames = "events+frames"
    case video

    /// The host keeps full frames, so `activity_frame` `size: full` can answer.
    public var keepsFullFrames: Bool { self != .events }
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
    /// What ties the session to an agent chat, when the host attributed it
    /// (`agent.acp_session`, `agent.harness_session_id`, `agent.workspace_id`):
    /// the live preview card shows in that chat.
    public var acpSession: String?
    public var harnessSessionID: String?
    public var workspaceID: String?
    /// Name, bundle id, process and window title of the app the session last acted on (its newest
    /// target). The legacy helper's targets name only the process.
    public var targetApp: String?
    public var targetBundleID: String?
    public var targetPID: Int32?
    public var targetWindowTitle: String?
    /// What the host stores for this session's frames.
    public var recording: AgentActivityRecording

    public init(
        id: String, machine: String, machineName: String, label: String, agentKind: String, agentName: String,
        attribution: AgentActivityAttribution, workspaceTitle: String? = nil, terminalTitle: String? = nil,
        colorHex: String, targetApps: [String] = [], status: AgentActivityStatus, startedAt: Date,
        lastActionAt: Date, endedAt: Date? = nil, acts: Int = 0, observes: Int = 0, errors: Int = 0,
        foregroundOnly: Bool = false, acpSession: String? = nil, harnessSessionID: String? = nil,
        workspaceID: String? = nil, targetApp: String? = nil, targetBundleID: String? = nil, targetPID: Int32? = nil,
        targetWindowTitle: String? = nil, recording: AgentActivityRecording = .events
    ) {
        self.recording = recording
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
        self.acpSession = acpSession
        self.harnessSessionID = harnessSessionID
        self.workspaceID = workspaceID
        self.targetApp = targetApp
        self.targetBundleID = targetBundleID
        self.targetPID = targetPID
        self.targetWindowTitle = targetWindowTitle
    }
}
