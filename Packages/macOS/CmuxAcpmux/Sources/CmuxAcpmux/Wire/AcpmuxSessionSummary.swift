import Foundation

/// A session row from `_acpmux/sessions`, `_acpmux/watch`, or `_acpmux/session_changed`.
///
/// Every field except ``sessionId`` is optional because acpmux omits empty values and a
/// purge notification carries only the id.
public struct AcpmuxSessionSummary: Sendable, Hashable, Codable, Identifiable {
    /// The acpmux session id.
    public var sessionId: String
    /// The short session name.
    public var name: String?
    /// The harness profile, for example `codex` or `claude-acp`.
    public var harness: String?
    /// The harness family, for example `claude`.
    public var family: String?
    /// The working directory.
    public var cwd: String?
    /// The title, auto-set from the first prompt line.
    public var title: String?
    /// One of `idle`, `ready`, `running`, `waiting`, `disconnected`, `closed`.
    public var status: String?
    /// Creation time in Unix milliseconds.
    public var createdAt: Int64?
    /// Last update time in Unix milliseconds.
    public var updatedAt: Int64?
    /// The newest event sequence number.
    public var lastSeq: Int?
    /// Number of turns run.
    public var turnCount: Int?
    /// The most recent prompt text.
    public var lastPrompt: String?
    /// The last agent text, at most 160 characters.
    public var preview: String?
    /// Number of queued prompts.
    public var queued: Int?
    /// The running turn, if any.
    public var turn: AcpmuxRunningTurn?
    /// Number of pending permission requests.
    public var pendingPermissions: Int?
    /// Pending permission requests.
    public var pending: [AcpmuxPendingPermission]?
    /// The selected model id.
    public var model: String?
    /// The reasoning effort.
    public var effort: String?
    /// Whether output arrived while nobody was attached.
    public var unread: Bool?
    /// The peer daemon name for remote sessions.
    public var peer: String?
    /// The last finished turn `{turnId, promptId, status, stopReason?, errorText?, errorSource?, endedAt}`
    /// (current acpmux), so a reattach can show a failure without replaying history.
    public var lastTurn: JSONValue?

    /// The session id.
    public var id: String { sessionId }

    /// Creates a summary with only an id, for tests and placeholders.
    public init(sessionId: String) {
        self.sessionId = sessionId
    }

    /// The best label for pickers: title, then name, then the id prefix.
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let name, !name.isEmpty { return name }
        return String(sessionId.prefix(8))
    }

    /// Whether a turn is in progress.
    public var isWorking: Bool { status == "running" || status == "waiting" || turn != nil }
}

/// The running turn attached to a session summary.
public struct AcpmuxRunningTurn: Sendable, Hashable, Codable {
    /// Turn start time in Unix milliseconds.
    public var startedAt: Int64?
    /// The client label that started it.
    public var client: String?
    /// The prompt text.
    public var prompt: String?
}

/// A permission request that waits for a human.
public struct AcpmuxPendingPermission: Sendable, Hashable, Codable {
    /// The id passed back in `_acpmux/permission_respond`.
    public var permissionId: String
    /// The ACP `session/request_permission` params.
    public var request: AcpmuxPermissionRequest
    /// Request time in Unix milliseconds.
    public var at: Int64?
}

/// The ACP permission request payload.
public struct AcpmuxPermissionRequest: Sendable, Hashable, Codable {
    /// The tool call that needs approval.
    public var toolCall: ToolCall?
    /// The choices offered.
    public var options: [Option]

    /// The tool call summary inside a permission request.
    public struct ToolCall: Sendable, Hashable, Codable {
        /// The tool call id.
        public var toolCallId: String?
        /// Human-readable title.
        public var title: String?
        /// ACP tool kind, for example `edit` or `execute`.
        public var kind: String?
        /// Raw tool input.
        public var rawInput: JSONValue?
    }

    /// One permission choice.
    public struct Option: Sendable, Hashable, Codable, Identifiable {
        /// The id sent back as `optionId`.
        public var optionId: String
        /// The button label.
        public var name: String
        /// `allow_once`, `allow_always`, `reject_once`, or `reject_always`.
        public var kind: String?
        /// The option id.
        public var id: String { optionId }
        /// Whether choosing this option allows the tool.
        public var isAllow: Bool { kind?.hasPrefix("allow") ?? false }
    }

    /// Creates a request.
    public init(toolCall: ToolCall?, options: [Option]) {
        self.toolCall = toolCall
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        toolCall = try container.decodeIfPresent(ToolCall.self, forKey: .toolCall)
        options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
    }
}

/// `_acpmux/attach` result: the session detail plus the newest events.
public struct AcpmuxAttachResult: Sendable, Codable {
    /// The session detail. Its summary fields decode into ``AcpmuxSessionSummary``.
    public var session: AcpmuxSessionDetail
    /// Events, oldest first.
    public var events: [AcpmuxEventRecord]
    /// Whether older matching records exist (current acpmux; `nil` from older daemons).
    public var hasMore: Bool?
    /// The session's newest sequence number (current acpmux).
    public var lastSeq: Int?
}

/// `_acpmux/info` and attach detail: the summary plus the prompt queue.
public struct AcpmuxSessionDetail: Sendable, Codable {
    /// Summary fields.
    public var summary: AcpmuxSessionSummary
    /// Queued prompts.
    public var queue: [AcpmuxQueueEntry]

    public init(from decoder: any Decoder) throws {
        summary = try AcpmuxSessionSummary(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queue = try container.decodeIfPresent([AcpmuxQueueEntry].self, forKey: .queue) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        try summary.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(queue, forKey: .queue)
    }

    private enum CodingKeys: String, CodingKey { case queue }
}

/// A queued prompt.
public struct AcpmuxQueueEntry: Sendable, Hashable, Codable, Identifiable {
    /// The prompt id.
    public var promptId: String
    /// The prompt text.
    public var text: String?
    /// The delivery mode, for example `turn`.
    public var delivery: String?
    /// The prompt id.
    public var id: String { promptId }

    /// Creates an entry.
    public init(promptId: String, text: String?, delivery: String?) {
        self.promptId = promptId
        self.text = text
        self.delivery = delivery
    }
}
