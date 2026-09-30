import Foundation

/// One rendered row of a chat transcript.
///
/// ``id`` is stable across updates so a view can reuse cells and keep scroll anchors;
/// ``version`` increases whenever ``content`` changes so height caches keyed by
/// `(id, version, width)` stay valid without comparing content.
public struct TranscriptRow: Sendable, Hashable, Identifiable {
    /// Stable identity, unique within one transcript.
    public let id: String
    /// Content revision. Starts at 0 and increases on every change.
    public internal(set) var version: Int
    /// Time of the first record in the row, Unix milliseconds.
    public internal(set) var at: Int64
    /// What the row shows.
    public internal(set) var content: TranscriptRowContent

    /// Creates a row.
    public init(id: String, version: Int = 0, at: Int64, content: TranscriptRowContent) {
        self.id = id
        self.version = version
        self.at = at
        self.content = content
    }

    /// Replaces the content and bumps ``version``.
    mutating func update(_ transform: (inout TranscriptRowContent) -> Void) {
        transform(&content)
        version += 1
    }

    /// The speaker for bubble grouping, or `nil` for rows that are not bubbles.
    public var bubbleRole: TranscriptBubbleRole? {
        switch content {
        case .user: return .user
        case .assistant: return .assistant
        default: return nil
        }
    }
}

/// Which side a bubble belongs to.
public enum TranscriptBubbleRole: Sendable, Hashable {
    /// The human, right-aligned.
    case user
    /// The agent, left-aligned.
    case assistant
}

/// The payload of a ``TranscriptRow``.
public enum TranscriptRowContent: Sendable, Hashable {
    /// A user message.
    case user(TranscriptUserMessage)
    /// Agent prose in Markdown. `isStreaming` is true while its turn runs.
    case assistant(text: String, isStreaming: Bool)
    /// A run of thoughts and tool calls between two pieces of prose.
    case activity(TranscriptActivityGroup)
    /// The agent's current plan.
    case plan([TranscriptPlanEntry])
    /// A permission request and its outcome.
    case permission(TranscriptPermissionCard)
    /// The end-of-turn divider, for example "Worked for 12s · 3 tool calls".
    case turnSummary(TranscriptTurnSummary)
    /// The agent is working and has produced no output yet in this turn.
    case typing
    /// A lifecycle notice such as a failed resume.
    case notice(String)
}

/// A user message bubble.
public struct TranscriptUserMessage: Sendable, Hashable {
    /// The message text.
    public var text: String
    /// True for a local echo the daemon has not confirmed yet.
    public var isPending: Bool
    /// True when sending failed.
    public var failed: Bool

    /// Creates a message.
    public init(text: String, isPending: Bool = false, failed: Bool = false) {
        self.text = text
        self.isPending = isPending
        self.failed = failed
    }
}

/// Thoughts and tool calls grouped under one collapsible header.
public struct TranscriptActivityGroup: Sendable, Hashable {
    /// Items in arrival order.
    public var items: [TranscriptActivityItem]
    /// True while the owning turn runs.
    public var isLive: Bool

    /// Number of tool calls in the group.
    public var toolCount: Int {
        items.reduce(0) { count, item in
            if case .tool = item { return count + 1 }
            return count
        }
    }

    /// The newest item, shown in the collapsed header.
    public var latest: TranscriptActivityItem? { items.last }
}

/// One entry in an activity group.
public enum TranscriptActivityItem: Sendable, Hashable {
    /// Agent reasoning text.
    case thought(String)
    /// A tool call.
    case tool(TranscriptToolCall)
}

/// A tool call with its latest status.
public struct TranscriptToolCall: Sendable, Hashable, Identifiable {
    /// ACP `toolCallId`.
    public var id: String
    /// Human-readable title.
    public var title: String
    /// ACP tool kind, for example `execute`.
    public var kind: String?
    /// `pending`, `in_progress`, `completed`, `failed`, or `cancelled`.
    public var status: String
    /// A one-line input summary, such as the shell command or file path.
    public var inputSummary: String?
    /// Output text, truncated for display.
    public var output: String?

    /// Whether the tool finished, successfully or not.
    public var isFinished: Bool { status == "completed" || status == "failed" || status == "cancelled" }
}

/// One plan entry.
public struct TranscriptPlanEntry: Sendable, Hashable {
    /// The step text.
    public var content: String
    /// `pending`, `in_progress`, or `completed`.
    public var status: String
}

/// A permission request rendered in the transcript.
public struct TranscriptPermissionCard: Sendable, Hashable {
    /// The id passed to `_acpmux/permission_respond`.
    public var permissionId: String
    /// The request payload.
    public var request: AcpmuxPermissionRequest
    /// The chosen option name, `nil` while pending.
    public var resolution: Resolution?

    /// How a permission request ended.
    public enum Resolution: Sendable, Hashable {
        /// An option was selected.
        case selected(optionId: String, allowed: Bool)
        /// The request was cancelled or declined.
        case cancelled
    }

    /// Whether the request still waits for a decision.
    public var isPending: Bool { resolution == nil }
}

/// The end-of-turn summary.
public struct TranscriptTurnSummary: Sendable, Hashable {
    /// Turn duration in milliseconds, when the start is known.
    public var durationMs: Int64?
    /// Tool calls made during the turn.
    public var toolCount: Int
    /// `completed`, `cancelled`, or `failed`.
    public var status: String
    /// The error message for a failed turn.
    public var error: String?

    /// Creates a summary.
    public init(durationMs: Int64?, toolCount: Int, status: String, error: String?) {
        self.durationMs = durationMs
        self.toolCount = toolCount
        self.status = status
        self.error = error
    }
}
