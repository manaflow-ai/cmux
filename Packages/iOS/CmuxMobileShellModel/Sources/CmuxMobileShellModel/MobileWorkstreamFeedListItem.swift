public import Foundation

/// One typed coding-agent feed row returned by `workstream.feed.list`.
public struct MobileWorkstreamFeedListItem: Decodable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let workstreamID: String
    public let source: String
    public let kind: String
    public let createdAt: Date
    public let updatedAt: Date
    public let cwd: String?
    public let title: String?
    public let workspaceID: String?
    public let surfaceID: String?
    public let status: MobileWorkstreamFeedStatus
    public let payload: MobileWorkstreamFeedPayload

    public init(
        id: UUID,
        workstreamID: String,
        source: String,
        kind: String,
        createdAt: Date,
        updatedAt: Date,
        cwd: String? = nil,
        title: String? = nil,
        workspaceID: String? = nil,
        surfaceID: String? = nil,
        status: MobileWorkstreamFeedStatus,
        payload: MobileWorkstreamFeedPayload
    ) {
        self.id = id
        self.workstreamID = workstreamID
        self.source = source
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cwd = cwd
        self.title = title
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.status = status
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, kind, status, title, cwd, decision, questions, selections, mode, feedback
        case workstreamID = "workstream_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case requestID = "request_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolInputSummary = "tool_input_summary"
        case supportedModes = "supported_modes"
        case plan, planSummary = "plan_summary", defaultMode = "default_mode"
        case toolResult = "tool_result", toolResultIsError = "tool_result_is_error"
        case text, reason
    }

    private enum DecisionKeys: String, CodingKey { case kind, mode, feedback, selections }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        workstreamID = try c.decode(String.self, forKey: .workstreamID)
        source = try c.decode(String.self, forKey: .source)
        kind = try c.decode(String.self, forKey: .kind)
        createdAt = try Date(
            c.decode(String.self, forKey: .createdAt),
            strategy: .iso8601
        )
        updatedAt = try Date(
            c.decode(String.self, forKey: .updatedAt),
            strategy: .iso8601
        )
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
        surfaceID = try c.decodeIfPresent(String.self, forKey: .surfaceID)

        let statusRaw = try c.decode(String.self, forKey: .status)
        switch statusRaw {
        case "pending": status = .pending
        case "expired": status = .expired
        case "telemetry": status = .telemetry
        case "resolved": status = .resolved(decision: Self.decodeDecision(c))
        default: status = .unknown(statusRaw)
        }

        let requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        switch kind {
        case "permissionRequest":
            guard let requestID else { throw Self.missing("request_id", decoder) }
            payload = .permission(
                requestID: requestID,
                toolName: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                safeInput: try c.decodeIfPresent(String.self, forKey: .toolInputSummary) ?? "",
                supportedModes: try c.decodeIfPresent([String].self, forKey: .supportedModes) ?? []
            )
        case "exitPlan":
            guard let requestID else { throw Self.missing("request_id", decoder) }
            payload = .exitPlan(
                requestID: requestID,
                plan: try c.decodeIfPresent(String.self, forKey: .plan) ?? "",
                summary: try c.decodeIfPresent(String.self, forKey: .planSummary),
                defaultMode: try c.decodeIfPresent(String.self, forKey: .defaultMode) ?? "manual"
            )
        case "question":
            guard let requestID else { throw Self.missing("request_id", decoder) }
            payload = .question(
                requestID: requestID,
                questions: try c.decodeIfPresent([MobileWorkstreamQuestion].self, forKey: .questions) ?? []
            )
        case "toolUse":
            payload = .toolUse(
                name: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                input: try c.decodeIfPresent(String.self, forKey: .toolInput) ?? ""
            )
        case "toolResult":
            payload = .toolResult(
                name: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                result: try c.decodeIfPresent(String.self, forKey: .toolResult) ?? "",
                isError: try c.decodeIfPresent(Bool.self, forKey: .toolResultIsError) ?? false
            )
        case "userPrompt", "assistantMessage":
            payload = .message(
                text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                fromUser: kind == "userPrompt"
            )
        case "stop": payload = .stop(reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "todos": payload = .todos
        case "sessionStart", "sessionEnd": payload = .lifecycle
        default: payload = .unknown(kind: kind)
        }
    }

    private static func decodeDecision(_ c: KeyedDecodingContainer<CodingKeys>) -> MobileWorkstreamDecision? {
        guard let nested = try? c.nestedContainer(keyedBy: DecisionKeys.self, forKey: .decision),
              let kind = try? nested.decode(String.self, forKey: .kind) else { return nil }
        switch kind {
        case "permission": return .permission(mode: (try? nested.decode(String.self, forKey: .mode)) ?? "")
        case "exit_plan": return .exitPlan(
            mode: (try? nested.decode(String.self, forKey: .mode)) ?? "",
            feedback: try? nested.decodeIfPresent(String.self, forKey: .feedback)
        )
        case "question": return .question(selections: (try? nested.decode([String].self, forKey: .selections)) ?? [])
        default: return .unknown(kind: kind)
        }
    }

    private static func missing(_ field: String, _ decoder: any Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing \(field)"))
    }
}
