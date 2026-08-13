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
        case id, source, kind, status, title, cwd, decision, questions, fields, selections, mode, feedback
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
        case interactionKind = "interaction_kind"
        case interactionKindCamel = "interactionKind"
        case booleanPrompt = "boolean_prompt"
        case booleanPromptCamel = "booleanPrompt"
        case booleanYesLabel = "boolean_yes_label"
        case booleanYesLabelCamel = "booleanYesLabel"
        case booleanNoLabel = "boolean_no_label"
        case booleanNoLabelCamel = "booleanNoLabel"
        case booleanDefault = "boolean_default"
        case booleanDefaultCamel = "booleanDefault"
        case formTitle = "form_title"
        case formTitleCamel = "formTitle"
        case formURL = "form_url"
        case formURLCamel = "formURL"
    }

    private enum DecisionKeys: String, CodingKey { case kind, mode, feedback, action, selections }

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
        switch statusRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending": status = .pending
        case "expired": status = .expired
        case "telemetry": status = .telemetry
        case "resolved": status = .resolved(decision: Self.decodeDecision(c))
        default: status = .unknown(statusRaw)
        }

        let requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        let normalizedKind = Self.normalizedToken(kind)
        switch normalizedKind {
        case "permissionrequest":
            guard let requestID else { throw Self.missing("request_id", decoder) }
            payload = .permission(
                requestID: requestID,
                toolName: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                safeInput: try c.decodeIfPresent(String.self, forKey: .toolInputSummary) ?? "",
                supportedModes: try c.decodeIfPresent([String].self, forKey: .supportedModes) ?? []
            )
        case "exitplan":
            guard let requestID else { throw Self.missing("request_id", decoder) }
            payload = .exitPlan(
                requestID: requestID,
                plan: try c.decodeIfPresent(String.self, forKey: .plan) ?? "",
                summary: try c.decodeIfPresent(String.self, forKey: .planSummary),
                defaultMode: try c.decodeIfPresent(String.self, forKey: .defaultMode) ?? "manual"
            )
        case "question", "boolean", "confirmation", "approval", "form", "elicitation",
             "questionrequest", "questionasked", "questionv2asked", "askuserquestion", "askuserconfirmation", "booleanquestion",
             "elicitationrequest", "mcpelicitation", "mcpserverelicitationrequest",
             "requestuserinput", "userinputrequest", "inputrequest", "toolrequestuserinput",
             "itemtoolrequestuserinput":
            guard let requestID else { throw Self.missing("request_id", decoder) }
            let questions = try c.decodeIfPresent([MobileWorkstreamQuestion].self, forKey: .questions)
                ?? c.decodeIfPresent([MobileWorkstreamQuestion].self, forKey: .fields)
                ?? []
            let rawInteractionKind = try c.decodeIfPresent(String.self, forKey: .interactionKind)
                ?? c.decodeIfPresent(String.self, forKey: .interactionKindCamel)
            let interactionKind = rawInteractionKind.map(Self.normalizedToken)
                ?? (["boolean", "confirmation", "approval", "booleanquestion"].contains(normalizedKind) ? "boolean" : nil)
                ?? (["form", "elicitation", "elicitationrequest", "mcpelicitation", "mcpserverelicitationrequest"].contains(normalizedKind) ? "form" : nil)
            if interactionKind == "boolean" {
                let first = questions.first
                let defaultValue = try c.decodeIfPresent(Bool.self, forKey: .booleanDefault)
                    ?? c.decodeIfPresent(Bool.self, forKey: .booleanDefaultCamel)
                    ?? first?.defaultValue.flatMap(Self.decodeBool)
                payload = .boolean(
                    requestID: requestID,
                    prompt: try c.decodeIfPresent(String.self, forKey: .booleanPrompt)
                        ?? c.decodeIfPresent(String.self, forKey: .booleanPromptCamel)
                        ?? first?.prompt
                        ?? "",
                    yesLabel: try c.decodeIfPresent(String.self, forKey: .booleanYesLabel)
                        ?? c.decodeIfPresent(String.self, forKey: .booleanYesLabelCamel)
                        ?? first?.options.first?.label
                        ?? "",
                    noLabel: try c.decodeIfPresent(String.self, forKey: .booleanNoLabel)
                        ?? c.decodeIfPresent(String.self, forKey: .booleanNoLabelCamel)
                        ?? first?.options.dropFirst().first?.label
                        ?? "",
                    defaultValue: defaultValue
                )
            } else if interactionKind == "form" {
                payload = .form(
                    requestID: requestID,
                    title: try c.decodeIfPresent(String.self, forKey: .formTitle)
                        ?? c.decodeIfPresent(String.self, forKey: .formTitleCamel),
                    fields: questions,
                    externalURL: try c.decodeIfPresent(String.self, forKey: .formURL)
                        ?? c.decodeIfPresent(String.self, forKey: .formURLCamel)
                        ?? questions.compactMap(\.externalURL).first
                )
            } else {
                payload = .question(requestID: requestID, questions: questions)
            }
        case "tooluse":
            payload = .toolUse(
                name: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                input: try c.decodeIfPresent(String.self, forKey: .toolInput) ?? ""
            )
        case "toolresult":
            payload = .toolResult(
                name: try c.decodeIfPresent(String.self, forKey: .toolName) ?? "",
                result: try c.decodeIfPresent(String.self, forKey: .toolResult) ?? "",
                isError: try c.decodeIfPresent(Bool.self, forKey: .toolResultIsError) ?? false
            )
        case "userprompt", "assistantmessage":
            payload = .message(
                text: try c.decodeIfPresent(String.self, forKey: .text) ?? "",
                fromUser: normalizedKind == "userprompt"
            )
        case "stop": payload = .stop(reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "todos": payload = .todos
        case "sessionstart", "sessionend": payload = .lifecycle
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
        case "form": return .form(
            action: (try? nested.decode(String.self, forKey: .action)) ?? "accept",
            selections: (try? nested.decode([String].self, forKey: .selections)) ?? []
        )
        default: return .unknown(kind: kind)
        }
    }

    private static func decodeBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on": return true
        case "0", "false", "no", "n", "off": return false
        default: return nil
        }
    }

    private static func normalizedToken(_ value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }

    private static func missing(_ field: String, _ decoder: any Decoder) -> DecodingError {
        .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing \(field)"))
    }
}
