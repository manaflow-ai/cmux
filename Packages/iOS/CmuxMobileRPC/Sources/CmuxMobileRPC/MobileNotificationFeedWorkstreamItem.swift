public import Foundation

/// One pending, actionable workstream item returned with the notification feed.
public struct MobileNotificationFeedWorkstreamItem: Decodable, Equatable, Sendable {
    public let id: String
    public let workstreamID: String
    public let workspaceID: String?
    public let surfaceID: String?
    public let source: String
    public let kind: String
    public let createdAt: Date
    public let requestID: String
    public let toolName: String?
    public let toolInput: String?
    public let plan: String?
    public let defaultMode: String?
    public let questions: [MobileNotificationFeedQuestion]

    private enum CodingKeys: String, CodingKey {
        case id
        case workstreamID = "workstream_id"
        case workspaceID = "workspace_id"
        case surfaceID = "surface_id"
        case source
        case kind
        case createdAt = "created_at"
        case requestID = "request_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case plan
        case defaultMode = "default_mode"
        case questions
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        workstreamID = try container.decode(String.self, forKey: .workstreamID)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        surfaceID = try container.decodeIfPresent(String.self, forKey: .surfaceID)
        source = try container.decode(String.self, forKey: .source)
        kind = try container.decode(String.self, forKey: .kind)
        requestID = try container.decode(String.self, forKey: .requestID)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        toolInput = try container.decodeIfPresent(String.self, forKey: .toolInput)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        defaultMode = try container.decodeIfPresent(String.self, forKey: .defaultMode)
        questions = try container.decodeIfPresent(
            [MobileNotificationFeedQuestion].self,
            forKey: .questions
        ) ?? []
        let rawDate = try container.decode(String.self, forKey: .createdAt)
        guard let parsedDate = ISO8601DateFormatter().date(from: rawDate) else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt,
                in: container,
                debugDescription: "Expected an ISO-8601 date"
            )
        }
        createdAt = parsedDate
    }
}

/// One prompt in a workstream question request.
public struct MobileNotificationFeedQuestion: Decodable, Equatable, Sendable {
    public let id: String
    public let header: String?
    public let prompt: String
    public let multiSelect: Bool
    public let options: [MobileNotificationFeedQuestionOption]

    private enum CodingKeys: String, CodingKey {
        case id, header, prompt, options
        case multiSelect = "multi_select"
    }
}

/// One preset choice in a workstream question prompt.
public struct MobileNotificationFeedQuestionOption: Decodable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String?
}
