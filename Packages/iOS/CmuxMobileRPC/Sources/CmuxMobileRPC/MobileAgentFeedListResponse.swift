public import Foundation

/// The authoritative response from `feed.list`.
public struct MobileAgentFeedListResponse: Decodable, Equatable, Sendable {
    /// The Mac's monotonically increasing workstream-feed revision.
    public let revision: Int
    /// The Mac's retained workstream items, newest first.
    public let items: [MobileAgentFeedListItem]

    private enum CodingKeys: String, CodingKey {
        case revision
        case items
    }

    /// Creates a feed list response from a revision and retained items.
    public init(revision: Int, items: [MobileAgentFeedListItem]) {
        self.revision = revision
        self.items = items
    }

    /// Decodes an agent-feed list response, dropping rows that violate the
    /// item contract instead of failing the whole snapshot. Older or newer
    /// Macs may emit rows this client cannot represent; the feed stays
    /// usable on the rows it can.
    public static func decode(_ data: Data) throws -> MobileAgentFeedListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int.self, forKey: .revision)
        var rows = try container.nestedUnkeyedContainer(forKey: .items)
        var decoded: [MobileAgentFeedListItem] = []
        if let count = rows.count {
            decoded.reserveCapacity(count)
        }
        while !rows.isAtEnd {
            if let row = try? rows.decode(MobileAgentFeedListItem.self) {
                decoded.append(row)
            } else {
                // Skip the malformed row; an unkeyed container only advances
                // on successful decode, so consume it as a throwaway blob.
                _ = try? rows.decode(MobileAgentFeedDiscardedRow.self)
            }
        }
        items = decoded
    }
}

/// A decode sink that accepts any JSON value, used to skip malformed rows.
private struct MobileAgentFeedDiscardedRow: Decodable {
    init(from decoder: any Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

/// One workstream item returned by the Mac's `feed.list` RPC. Field names
/// mirror the Mac control socket's `FeedSocketEncoding.itemDict` plus the
/// mobile-only routing and context enrichment.
public struct MobileAgentFeedListItem: Decodable, Equatable, Sendable {
    /// The Mac-local item identifier.
    public let id: String
    /// The owning workstream (`<agent>-<sessionId>`).
    public let workstreamID: String
    /// The emitting agent's wire name (`claude`, `codex`, ...).
    public let source: String
    /// The item kind's wire name (`permission_request`, `question`, ...).
    public let kind: String
    /// The item's lifecycle status wire name (`pending`, `resolved`, `expired`, `telemetry`).
    public let status: String
    public let createdAt: Date
    public let updatedAt: Date
    public let title: String?
    public let cwd: String?
    /// The reply correlation id for actionable items.
    public let requestID: String?
    public let toolName: String?
    public let toolInput: String?
    public let toolResult: String?
    public let toolResultIsError: Bool?
    /// The full plan text for exit-plan items.
    public let plan: String?
    public let planSummary: String?
    /// The exit-plan approval mode preselected by the agent.
    public let defaultMode: String?
    /// The prompts for question items.
    public let questions: [MobileAgentFeedListQuestion]
    /// The free text of user-prompt and assistant-message telemetry.
    public let text: String?
    /// The stop reason for turn-complete telemetry, when the agent gave one.
    public let reason: String?
    /// The recorded decision for resolved items.
    public let decision: MobileAgentFeedListDecision?
    /// The Mac-resolved target workspace, when the workstream maps to one.
    public let workspaceID: String?
    /// The Mac-resolved target pane or terminal surface.
    public let surfaceID: String?
    public let workspaceTitle: String?
    public let surfaceTitle: String?
    /// Nearby conversation context carried with the item.
    public let context: MobileAgentFeedListContext?

    private enum CodingKeys: String, CodingKey {
        case id
        case workstreamID = "workstream_id"
        case source
        case kind
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case title
        case cwd
        case requestID = "request_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolResult = "tool_result"
        case toolResultIsError = "tool_result_is_error"
        case plan
        case planSummary = "plan_summary"
        case defaultMode = "default_mode"
        case questions
        case text
        case reason
        case decision
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case workspaceTitle = "workspace_title"
        case surfaceTitle = "surface_title"
        case context
    }

    public init(
        id: String,
        workstreamID: String,
        source: String,
        kind: String,
        status: String,
        createdAt: Date,
        updatedAt: Date,
        title: String? = nil,
        cwd: String? = nil,
        requestID: String? = nil,
        toolName: String? = nil,
        toolInput: String? = nil,
        toolResult: String? = nil,
        toolResultIsError: Bool? = nil,
        plan: String? = nil,
        planSummary: String? = nil,
        defaultMode: String? = nil,
        questions: [MobileAgentFeedListQuestion] = [],
        text: String? = nil,
        reason: String? = nil,
        decision: MobileAgentFeedListDecision? = nil,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        workspaceTitle: String? = nil,
        surfaceTitle: String? = nil,
        context: MobileAgentFeedListContext? = nil
    ) {
        self.id = id
        self.workstreamID = workstreamID
        self.source = source
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.title = title
        self.cwd = cwd
        self.requestID = requestID
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolResult = toolResult
        self.toolResultIsError = toolResultIsError
        self.plan = plan
        self.planSummary = planSummary
        self.defaultMode = defaultMode
        self.questions = questions
        self.text = text
        self.reason = reason
        self.decision = decision
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.workspaceTitle = workspaceTitle
        self.surfaceTitle = surfaceTitle
        self.context = context
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workstreamID = try container.decode(String.self, forKey: .workstreamID)
        source = try container.decode(String.self, forKey: .source)
        kind = try container.decode(String.self, forKey: .kind)
        status = try container.decode(String.self, forKey: .status)
        createdAt = try Self.date(from: container, forKey: .createdAt)
        updatedAt = try Self.date(from: container, forKey: .updatedAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        requestID = try container.decodeIfPresent(String.self, forKey: .requestID)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolInput = try container.decodeIfPresent(String.self, forKey: .toolInput)
        toolResult = try container.decodeIfPresent(String.self, forKey: .toolResult)
        toolResultIsError = try container.decodeIfPresent(Bool.self, forKey: .toolResultIsError)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        planSummary = try container.decodeIfPresent(String.self, forKey: .planSummary)
        defaultMode = try container.decodeIfPresent(String.self, forKey: .defaultMode)
        questions = try container.decodeIfPresent(
            [MobileAgentFeedListQuestion].self,
            forKey: .questions
        ) ?? []
        text = try container.decodeIfPresent(String.self, forKey: .text)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        decision = try container.decodeIfPresent(MobileAgentFeedListDecision.self, forKey: .decision)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID)
        workspaceTitle = try container.decodeIfPresent(String.self, forKey: .workspaceTitle)
        surfaceTitle = try container.decodeIfPresent(String.self, forKey: .surfaceTitle)
        context = try container.decodeIfPresent(MobileAgentFeedListContext.self, forKey: .context)
    }

    /// The wire carries ISO8601 timestamps (the Mac side encodes with
    /// `ISO8601DateFormatter`); tolerate epoch seconds for forward
    /// compatibility with hosts that switch to numeric dates.
    private static func date(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Date {
        if let raw = try? container.decode(String.self, forKey: key) {
            if let date = mobileAgentFeedISO8601Formatter.date(from: raw) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "Unrecognized date format: \(raw)"
            )
        }
        let seconds = try container.decode(Double.self, forKey: key)
        return Date(timeIntervalSince1970: seconds)
    }
}

/// `NSISO8601DateFormatter` is documented thread-safe; the annotation only
/// silences the strict-concurrency diagnostic for this immutable global.
nonisolated(unsafe) private let mobileAgentFeedISO8601Formatter = ISO8601DateFormatter()

/// One question prompt attached to a question item.
public struct MobileAgentFeedListQuestion: Decodable, Equatable, Sendable {
    public let id: String
    public let header: String?
    public let prompt: String
    public let multiSelect: Bool
    public let options: [MobileAgentFeedListQuestionOption]

    private enum CodingKeys: String, CodingKey {
        case id
        case header
        case prompt
        case multiSelect = "multi_select"
        case options
    }

    public init(
        id: String,
        header: String? = nil,
        prompt: String,
        multiSelect: Bool = false,
        options: [MobileAgentFeedListQuestionOption] = []
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.multiSelect = multiSelect
        self.options = options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        header = try container.decodeIfPresent(String.self, forKey: .header)
        prompt = try container.decode(String.self, forKey: .prompt)
        multiSelect = try container.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        options = try container.decodeIfPresent(
            [MobileAgentFeedListQuestionOption].self,
            forKey: .options
        ) ?? []
    }
}

/// One selectable option of a question prompt.
public struct MobileAgentFeedListQuestionOption: Decodable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

/// The recorded decision of a resolved item.
public struct MobileAgentFeedListDecision: Decodable, Equatable, Sendable {
    /// The decision family (`permission`, `exit_plan`, `question`).
    public let kind: String
    /// The chosen mode for permission and exit-plan decisions.
    public let mode: String?
    /// The chosen option ids or free text for question decisions.
    public let selections: [String]
    /// The revise feedback for exit-plan decisions.
    public let feedback: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case mode
        case selections
        case feedback
    }

    public init(
        kind: String,
        mode: String? = nil,
        selections: [String] = [],
        feedback: String? = nil
    ) {
        self.kind = kind
        self.mode = mode
        self.selections = selections
        self.feedback = feedback
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(String.self, forKey: .kind)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        selections = try container.decodeIfPresent([String].self, forKey: .selections) ?? []
        feedback = try container.decodeIfPresent(String.self, forKey: .feedback)
    }
}

/// Nearby conversation context carried with a feed item.
public struct MobileAgentFeedListContext: Decodable, Equatable, Sendable {
    public let lastUserMessage: String?
    public let assistantPreamble: String?
    public let planSummary: String?
    public let toolSummary: String?
    public let permissionMode: String?

    private enum CodingKeys: String, CodingKey {
        case lastUserMessage = "last_user_message"
        case assistantPreamble = "assistant_preamble"
        case planSummary = "plan_summary"
        case toolSummary = "tool_summary"
        case permissionMode = "permission_mode"
    }

    public init(
        lastUserMessage: String? = nil,
        assistantPreamble: String? = nil,
        planSummary: String? = nil,
        toolSummary: String? = nil,
        permissionMode: String? = nil
    ) {
        self.lastUserMessage = lastUserMessage
        self.assistantPreamble = assistantPreamble
        self.planSummary = planSummary
        self.toolSummary = toolSummary
        self.permissionMode = permissionMode
    }
}
