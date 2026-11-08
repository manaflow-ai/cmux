public import Foundation

/// One coding-agent session hosted by a workspace's terminals, projected for
/// the custom-sidebar interpreter context (`workspaces[i].agents[j]`).
///
/// The app resolves each field from the live agent-chat session registry
/// (hook-event derived; see `AgentChatSessionRecord`); the data-context
/// builder maps it to the `agents[j]` value object. Optional fields are `nil`
/// when absent so interpreted `if let` / ternary truthiness behaves; `nil`
/// and empty strings are both treated as absent.
public struct CustomSidebarAgentSnapshot: Sendable, Equatable {
    /// The agent's own session identifier (`agents[j].id`).
    public let sessionId: String
    /// The agent runtime's raw source name, e.g. "claude" / "codex"
    /// (`agents[j].kind`).
    public let kind: String
    /// Short human-readable runtime name, e.g. "Claude" (`agents[j].name`).
    public let name: String
    /// The live state's wire name: "idle" | "working" | "needs_input" |
    /// "ended" (`agents[j].status`).
    public let status: String
    /// When the current working/needs-input state began; `nil` for idle and
    /// ended (`agents[j].sinceEpoch`).
    public let stateSince: Date?
    /// The most recent hook or transcript activity (`agents[j].lastActivityAt`).
    public let lastActivityAt: Date
    /// Conversation title (first user prompt), when known (`agents[j].title`).
    public let title: String?
    /// The hosting terminal panel's UUID, matching `tabs[k].id`
    /// (`agents[j].panelId`).
    public let panelId: UUID?
    /// The hosting tab's surface UUID, matching `tabs[k].surfaceId`; the id
    /// `surface.focus` accepts (`agents[j].surfaceId`).
    public let surfaceId: UUID?
    /// The session's working directory, when known (`agents[j].directory`).
    public let workingDirectory: String?
    /// Absolute transcript JSONL path, when resolved
    /// (`agents[j].transcriptPath`).
    public let transcriptPath: String?
    /// The agent process id, when known (`agents[j].pid`).
    public let pid: Int?
    /// Child agent runs (Claude Task spawns, Codex subagent runs) observed
    /// under this session (`agents[j].children`).
    public let children: [CustomSidebarAgentChildSnapshot]

    /// Creates an agent snapshot from already-resolved leaf values.
    public init(
        sessionId: String,
        kind: String,
        name: String,
        status: String,
        stateSince: Date?,
        lastActivityAt: Date,
        title: String?,
        panelId: UUID?,
        surfaceId: UUID?,
        workingDirectory: String?,
        transcriptPath: String?,
        pid: Int?,
        children: [CustomSidebarAgentChildSnapshot] = []
    ) {
        self.sessionId = sessionId
        self.kind = kind
        self.name = name
        self.status = status
        self.stateSince = stateSince
        self.lastActivityAt = lastActivityAt
        self.title = title
        self.panelId = panelId
        self.surfaceId = surfaceId
        self.workingDirectory = workingDirectory
        self.transcriptPath = transcriptPath
        self.pid = pid
        self.children = children
    }
}

/// One child agent run under a parent session
/// (`workspaces[i].agents[j].children[k]`).
public struct CustomSidebarAgentChildSnapshot: Sendable, Equatable {
    /// Correlation id, stable for the child's lifetime (`children[k].id`).
    public let id: String
    /// Human label - the Task description or subagent type, when known
    /// (`children[k].label`).
    public let label: String?
    /// Whether the child is still running (`children[k].running`).
    public let isRunning: Bool
    /// When the child started (`children[k].startedEpoch`).
    public let startedAt: Date
    /// When the child settled; `nil` while running (`children[k].endedEpoch`).
    public let endedAt: Date?

    public init(id: String, label: String?, isRunning: Bool, startedAt: Date, endedAt: Date?) {
        self.id = id
        self.label = label
        self.isRunning = isRunning
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}
