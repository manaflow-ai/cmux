/// One Claude Code agent session projected into the custom-sidebar interpreter
/// context (the top-level `agents` array).
///
/// Mirrors a single entry of `claude agents --json --all`: every live session
/// plus background sessions that are still working or blocked, and (with
/// `--all`) completed background sessions. Optional fields follow the CLI's own
/// presence rules — e.g. `id` and `state` appear for background sessions,
/// `pid`/`status` only while the process is alive, and `waitingFor` only when a
/// session is blocked on something such as a permission prompt.
public struct CustomSidebarAgentSnapshot: Sendable, Equatable {
    /// The short background-session id (usable with `claude attach/logs/stop`),
    /// or `nil` for interactive sessions that have no background id.
    public let id: String?
    /// The session's working directory. Used to group sessions by project.
    public let cwd: String
    /// `background` or `interactive`.
    public let kind: String
    /// The session's display name, when one was set.
    public let name: String?
    /// The full conversation/session UUID, when present.
    public let sessionId: String?
    /// Background lifecycle state: `working`, `blocked`, `done`, `failed`, or
    /// `stopped`. `nil` for plain interactive sessions.
    public let state: String?
    /// Live process status (e.g. `busy`, `idle`, `waiting`), present only while
    /// the process is alive.
    public let status: String?
    /// The OS process id, present only while the process is alive.
    public let pid: Int?
    /// Start time in milliseconds since the Unix epoch, when reported.
    public let startedAt: Int?
    /// What a blocked session is waiting on (e.g. `permission prompt`), present
    /// only while `status` is `waiting`.
    public let waitingFor: String?

    /// Creates an agent-session snapshot from already-resolved values.
    public init(
        id: String?,
        cwd: String,
        kind: String,
        name: String?,
        sessionId: String?,
        state: String?,
        status: String?,
        pid: Int?,
        startedAt: Int?,
        waitingFor: String?
    ) {
        self.id = id
        self.cwd = cwd
        self.kind = kind
        self.name = name
        self.sessionId = sessionId
        self.state = state
        self.status = status
        self.pid = pid
        self.startedAt = startedAt
        self.waitingFor = waitingFor
    }
}
