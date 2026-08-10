import Foundation

/// One answer option in an AskUserQuestion payload.
public struct MobileWorkstreamQuestionOption: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?

    public init(id: String, label: String, description: String? = nil) {
        self.id = id
        self.label = label
        self.description = description
    }
}

/// One prompt in a multi-question AskUserQuestion request.
public struct MobileWorkstreamQuestion: Decodable, Equatable, Sendable, Identifiable {
    public let id: String
    public let header: String?
    public let prompt: String
    public let multiSelect: Bool
    public let options: [MobileWorkstreamQuestionOption]

    public init(
        id: String,
        header: String? = nil,
        prompt: String,
        multiSelect: Bool,
        options: [MobileWorkstreamQuestionOption]
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.multiSelect = multiSelect
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case id, header, prompt, options
        case multiSelect = "multi_select"
    }
}

/// Forward-compatible typed presentation payload for one workstream event.
public enum MobileWorkstreamFeedPayload: Equatable, Sendable {
    case permission(requestID: String, toolName: String, safeInput: String, supportedModes: [String])
    case exitPlan(requestID: String, plan: String, summary: String?, defaultMode: String)
    case question(requestID: String, questions: [MobileWorkstreamQuestion])
    case toolUse(name: String, input: String)
    case toolResult(name: String, result: String, isError: Bool)
    case message(text: String, fromUser: Bool)
    case stop(reason: String?)
    case todos
    case lifecycle
    case unknown(kind: String)
}
