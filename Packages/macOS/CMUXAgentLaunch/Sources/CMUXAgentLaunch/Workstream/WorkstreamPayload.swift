import Foundation

/// Inline permission decision modes the user can pick on a
/// `.permissionRequest` item. Wire format uses the lowercase raw values.
public enum WorkstreamPermissionMode: String, Codable, Sendable, Equatable, CaseIterable {
    case once
    case always
    case all
    case bypass
    case deny
}

/// Inline plan-mode decision the user can pick on an `.exitPlan` item.
public enum WorkstreamExitPlanMode: String, Codable, Sendable, Equatable, CaseIterable {
    case ultraplan
    case bypassPermissions
    case autoAccept
    case manual
    case deny
}

/// Single option on an `.question` item.
public struct WorkstreamQuestionOption: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    /// Optional longer description for each option. When present,
    /// the Feed renders the option in long-form card style with the
    /// description as secondary text.
    public let description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

/// One prompt inside a `.question` payload. Claude Code's
/// `AskUserQuestion` tool can include several questions in a single
/// call, so a payload carries an array of these.
public struct WorkstreamQuestionPrompt: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Optional short header / category (e.g. Claude's "[Demo task]").
    /// Rendered above the prompt when present.
    public let header: String?
    public let prompt: String
    public let multiSelect: Bool
    public let options: [WorkstreamQuestionOption]

    public init(
        id: String,
        header: String? = nil,
        prompt: String,
        multiSelect: Bool,
        options: [WorkstreamQuestionOption]
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.multiSelect = multiSelect
        self.options = options
    }
}

/// Task-list entry reported by Claude's `TodoWrite` tool or equivalent.
public struct WorkstreamTaskTodo: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, Equatable {
        case pending
        case inProgress
        case completed
    }

    public let id: String
    public let content: String
    public let state: State

    public init(id: String, content: String, state: State) {
        self.id = id
        self.content = content
        self.state = state
    }
}

/// Kind-specific payload for a `WorkstreamItem`.
public enum WorkstreamPayload: Codable, Sendable, Equatable {
    case permissionRequest(
        requestId: String,
        toolName: String,
        toolInputJSON: String,
        pattern: String?
    )
    case exitPlan(
        requestId: String,
        plan: String,
        defaultMode: WorkstreamExitPlanMode
    )
    case question(
        requestId: String,
        questions: [WorkstreamQuestionPrompt]
    )
    case toolUse(toolName: String, toolInputJSON: String)
    case toolResult(toolName: String, resultJSON: String, isError: Bool)
    case userPrompt(text: String)
    case assistantMessage(text: String)
    case sessionStart
    case sessionEnd
    case stop(reason: String?)
    case todos([WorkstreamTaskTodo])

    private enum CaseKey: String, CodingKey {
        case permissionRequest
        case exitPlan
        case question
        case toolUse
        case toolResult
        case userPrompt
        case assistantMessage
        case sessionStart
        case sessionEnd
        case stop
        case todos
    }

    private enum PermissionKeys: String, CodingKey {
        case requestId
        case toolName
        case toolInputJSON
        case pattern
    }

    private enum ExitPlanKeys: String, CodingKey {
        case requestId
        case plan
        case defaultMode
    }

    private enum QuestionKeys: String, CodingKey {
        case requestId
        case questions
        case prompt
        case options
        case multiSelect
    }

    private enum ToolUseKeys: String, CodingKey {
        case toolName
        case toolInputJSON
    }

    private enum ToolResultKeys: String, CodingKey {
        case toolName
        case resultJSON
        case isError
    }

    private enum TextKeys: String, CodingKey {
        case text
    }

    private enum StopKeys: String, CodingKey {
        case reason
    }

    private enum UnlabeledKeys: String, CodingKey {
        case value = "_0"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CaseKey.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected WorkstreamPayload case"
                )
            )
        }

        switch key {
        case .permissionRequest:
            let p = try c.nestedContainer(keyedBy: PermissionKeys.self, forKey: key)
            self = .permissionRequest(
                requestId: try p.decode(String.self, forKey: .requestId),
                toolName: try p.decode(String.self, forKey: .toolName),
                toolInputJSON: try p.decode(String.self, forKey: .toolInputJSON),
                pattern: try p.decodeIfPresent(String.self, forKey: .pattern)
            )
        case .exitPlan:
            let p = try c.nestedContainer(keyedBy: ExitPlanKeys.self, forKey: key)
            self = .exitPlan(
                requestId: try p.decode(String.self, forKey: .requestId),
                plan: try p.decode(String.self, forKey: .plan),
                defaultMode: try p.decode(WorkstreamExitPlanMode.self, forKey: .defaultMode)
            )
        case .question:
            let p = try c.nestedContainer(keyedBy: QuestionKeys.self, forKey: key)
            let requestId = try p.decode(String.self, forKey: .requestId)
            if let questions = try p.decodeIfPresent(
                [WorkstreamQuestionPrompt].self,
                forKey: .questions
            ) {
                self = .question(requestId: requestId, questions: questions)
            } else {
                self = .question(
                    requestId: requestId,
                    questions: [
                        WorkstreamQuestionPrompt(
                            id: "q0",
                            prompt: try p.decodeIfPresent(String.self, forKey: .prompt) ?? "",
                            multiSelect: try p.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false,
                            options: try p.decodeIfPresent(
                                [WorkstreamQuestionOption].self,
                                forKey: .options
                            ) ?? []
                        )
                    ]
                )
            }
        case .toolUse:
            let p = try c.nestedContainer(keyedBy: ToolUseKeys.self, forKey: key)
            self = .toolUse(
                toolName: try p.decode(String.self, forKey: .toolName),
                toolInputJSON: try p.decode(String.self, forKey: .toolInputJSON)
            )
        case .toolResult:
            let p = try c.nestedContainer(keyedBy: ToolResultKeys.self, forKey: key)
            self = .toolResult(
                toolName: try p.decode(String.self, forKey: .toolName),
                resultJSON: try p.decode(String.self, forKey: .resultJSON),
                isError: try p.decode(Bool.self, forKey: .isError)
            )
        case .userPrompt:
            let p = try c.nestedContainer(keyedBy: TextKeys.self, forKey: key)
            self = .userPrompt(text: try p.decode(String.self, forKey: .text))
        case .assistantMessage:
            let p = try c.nestedContainer(keyedBy: TextKeys.self, forKey: key)
            self = .assistantMessage(text: try p.decode(String.self, forKey: .text))
        case .sessionStart:
            self = .sessionStart
        case .sessionEnd:
            self = .sessionEnd
        case .stop:
            let p = try c.nestedContainer(keyedBy: StopKeys.self, forKey: key)
            self = .stop(reason: try p.decodeIfPresent(String.self, forKey: .reason))
        case .todos:
            let p = try c.nestedContainer(keyedBy: UnlabeledKeys.self, forKey: key)
            self = .todos(try p.decode([WorkstreamTaskTodo].self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .permissionRequest(let requestId, let toolName, let toolInputJSON, let pattern):
            var p = c.nestedContainer(keyedBy: PermissionKeys.self, forKey: .permissionRequest)
            try p.encode(requestId, forKey: .requestId)
            try p.encode(toolName, forKey: .toolName)
            try p.encode(toolInputJSON, forKey: .toolInputJSON)
            try p.encodeIfPresent(pattern, forKey: .pattern)
        case .exitPlan(let requestId, let plan, let defaultMode):
            var p = c.nestedContainer(keyedBy: ExitPlanKeys.self, forKey: .exitPlan)
            try p.encode(requestId, forKey: .requestId)
            try p.encode(plan, forKey: .plan)
            try p.encode(defaultMode, forKey: .defaultMode)
        case .question(let requestId, let questions):
            var p = c.nestedContainer(keyedBy: QuestionKeys.self, forKey: .question)
            try p.encode(requestId, forKey: .requestId)
            try p.encode(questions, forKey: .questions)
        case .toolUse(let toolName, let toolInputJSON):
            var p = c.nestedContainer(keyedBy: ToolUseKeys.self, forKey: .toolUse)
            try p.encode(toolName, forKey: .toolName)
            try p.encode(toolInputJSON, forKey: .toolInputJSON)
        case .toolResult(let toolName, let resultJSON, let isError):
            var p = c.nestedContainer(keyedBy: ToolResultKeys.self, forKey: .toolResult)
            try p.encode(toolName, forKey: .toolName)
            try p.encode(resultJSON, forKey: .resultJSON)
            try p.encode(isError, forKey: .isError)
        case .userPrompt(let text):
            var p = c.nestedContainer(keyedBy: TextKeys.self, forKey: .userPrompt)
            try p.encode(text, forKey: .text)
        case .assistantMessage(let text):
            var p = c.nestedContainer(keyedBy: TextKeys.self, forKey: .assistantMessage)
            try p.encode(text, forKey: .text)
        case .sessionStart:
            _ = c.nestedContainer(keyedBy: UnlabeledKeys.self, forKey: .sessionStart)
        case .sessionEnd:
            _ = c.nestedContainer(keyedBy: UnlabeledKeys.self, forKey: .sessionEnd)
        case .stop(let reason):
            var p = c.nestedContainer(keyedBy: StopKeys.self, forKey: .stop)
            try p.encodeIfPresent(reason, forKey: .reason)
        case .todos(let todos):
            var p = c.nestedContainer(keyedBy: UnlabeledKeys.self, forKey: .todos)
            try p.encode(todos, forKey: .value)
        }
    }
}
