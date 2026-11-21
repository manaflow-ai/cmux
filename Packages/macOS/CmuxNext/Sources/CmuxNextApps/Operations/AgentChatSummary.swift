public import Foundation

/// One agent chat as `agent_chat.list` gives it to a script: what the sidebar knows of the chat
/// (its acpmux lane), as plain values, so a customize section can list chats as threads.
public nonisolated struct AgentChatSummary: Equatable, Sendable {
    /// acpmux's id of the session.
    public var id: String
    /// The chat's title (acpmux's masked title, else its name).
    public var title: String
    /// The harness that runs it ("claude", "codex"), when known.
    public var harness: String?
    /// What it does: `working`, `input` (waits for the person), `idle`, `failed` or `lost`.
    public var state: String
    /// A turn ended while nobody showed the chat.
    public var unread: Bool
    /// The session folder's name (the last part of `cwd`).
    public var project: String?
    /// The session folder.
    public var cwd: String?
    /// The cmux workspace that shows the chat, when it is bound to one.
    public var workspace: String?
    /// The acpmux peer that owns the chat; nil on this Mac.
    public var machine: String?
    /// What it does now, one line.
    public var step: String?
    /// The last turn's error when `failed` or `lost`.
    public var error: String?
    /// Since when it has been in `state`.
    public var since: Date?
    /// Its last output.
    public var updatedAt: Date?
    /// When the session started.
    public var createdAt: Date?
    /// The pull requests it opened (their URLs).
    public var pullRequests: [String]

    /// Creates a chat summary; every field is the lane's own value.
    /// - Parameters:
    ///   - id: acpmux's session id.
    ///   - title: The chat's title.
    ///   - harness: The harness name, when known.
    ///   - state: `working`, `input`, `idle`, `failed` or `lost`.
    ///   - unread: Whether a turn ended unseen.
    ///   - project: The folder's name.
    ///   - cwd: The folder.
    ///   - workspace: The bound cmux workspace id.
    ///   - machine: The owning acpmux peer; nil on this Mac.
    ///   - step: The current step, one line.
    ///   - error: The last turn's error.
    ///   - since: Since when it has been in `state`.
    ///   - updatedAt: Its last output.
    ///   - createdAt: Its start.
    ///   - pullRequests: The pull request URLs it opened.
    public init(id: String, title: String, harness: String?, state: String, unread: Bool, project: String?, cwd: String?,
                workspace: String?, machine: String?, step: String?, error: String?, since: Date?, updatedAt: Date?,
                createdAt: Date?, pullRequests: [String]) {
        self.id = id
        self.title = title
        self.harness = harness
        self.state = state
        self.unread = unread
        self.project = project
        self.cwd = cwd
        self.workspace = workspace
        self.machine = machine
        self.step = step
        self.error = error
        self.since = since
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.pullRequests = pullRequests
    }

    /// The chat in the script's shape: snake_case keys, times as epoch milliseconds, null for unknown.
    var appJSON: AppJSON {
        func text(_ value: String?) -> AppJSON { value.map(AppJSON.string) ?? .null }
        func time(_ value: Date?) -> AppJSON { value.map { .number(($0.timeIntervalSince1970 * 1000).rounded()) } ?? .null }
        return [
            "id": .string(id), "title": .string(title), "harness": text(harness), "state": .string(state), "unread": .bool(unread),
            "project": text(project), "cwd": text(cwd), "workspace": text(workspace), "machine": text(machine),
            "step": text(step), "error": text(error), "since_ms": time(since), "updated_ms": time(updatedAt),
            "created_ms": time(createdAt), "pull_requests": .array(pullRequests.map(AppJSON.string)),
        ]
    }
}
