public import Foundation

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
