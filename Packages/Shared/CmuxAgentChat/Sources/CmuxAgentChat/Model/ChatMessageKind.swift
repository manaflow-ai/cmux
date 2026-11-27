/// The typed payload of a ``ChatMessage``; renderers switch over this.
///
/// Encodes on the wire as `{"type": "<case>", ...payload keys inlined...}`
/// so non-Swift consumers and logs stay readable. Unknown types decode as
/// ``ChatMessageKind/unsupported(_:)`` so older clients fail open instead of
/// dropping content (product rule: never lose content).
public enum ChatMessageKind: Sendable, Equatable {
    /// Conversational text, markdown-capable. User prompts and agent prose.
    case prose(ChatProse)
    /// A collapsed reasoning/thinking block produced by the agent.
    case thought(ChatThought)
    /// A non-terminal tool invocation (read, search, web fetch, subagent...).
    case toolUse(ChatToolUse)
    /// A shell command and its captured output; renders as a terminal card.
    case terminal(ChatTerminalCapture)
    /// A file edit; renders as a diff card.
    case fileEdit(ChatFileEdit)
    /// An actionable permission request awaiting the user's decision.
    case permissionRequest(ChatPermissionRequest)
    /// A multiple-choice question the agent asked the user.
    case question(ChatQuestion)
    /// A durable session lifecycle transition; renders as a centered caption.
    case status(ChatStatusTransition)
    /// An image or file the user attached to a prompt.
    case attachment(ChatAttachment)
    /// A payload type this client does not understand; renders as raw text.
    case unsupported(ChatUnsupportedPayload)
}

extension ChatMessageKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
    }

    private enum TypeName: String {
        case prose
        case thought
        case toolUse = "tool_use"
        case terminal
        case fileEdit = "file_edit"
        case permissionRequest = "permission_request"
        case question
        case status
        case attachment
        case unsupported
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        // Payload decode failures fail OPEN to the unsupported row: a newer
        // Mac adding one nested enum value (a new tool status, a new media
        // kind) must degrade that single message, not throw the whole page
        // or event frame away.
        do {
            switch TypeName(rawValue: rawType) {
            case .prose:
                self = .prose(try ChatProse(from: decoder))
            case .thought:
                self = .thought(try ChatThought(from: decoder))
            case .toolUse:
                self = .toolUse(try ChatToolUse(from: decoder))
            case .terminal:
                self = .terminal(try ChatTerminalCapture(from: decoder))
            case .fileEdit:
                self = .fileEdit(try ChatFileEdit(from: decoder))
            case .permissionRequest:
                self = .permissionRequest(try ChatPermissionRequest(from: decoder))
            case .question:
                self = .question(try ChatQuestion(from: decoder))
            case .status:
                self = .status(try ChatStatusTransition(from: decoder))
            case .attachment:
                self = .attachment(try ChatAttachment(from: decoder))
            case .unsupported, .none:
                self = .unsupported(ChatUnsupportedPayload(rawType: rawType))
            }
        } catch {
            self = .unsupported(ChatUnsupportedPayload(rawType: rawType))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .prose(let payload):
            try container.encode(TypeName.prose.rawValue, forKey: .type)
            try payload.encode(to: encoder)
        case .thought(let payload):
            try container.encode(TypeName.thought.rawValue, forKey: .type)
            try payload.encode(to: encoder)
        case .toolUse(let payload):
            try container.encode(TypeName.toolUse.rawValue, forKey: .type)
            try payload.encode(to: encoder)
        case .terminal(let payload):
            try container.encode(TypeName.terminal.rawValue, forKey: .type)
            try payload.encode(to: encoder)
        case .fileEdit(let payload):
            try container.encode(TypeName.fileEdit.rawValue, forKey: .type)
            try payload.encode(to: encoder)
        case .permissionRequest(let payload):
            try container.encode(TypeName.permissionRequest.rawValue, forKey: .type)
            try payload.encode(to: encoder)
        case .question(let payload):
            try container.encode(TypeName.question.rawValue, forKey: .type)
            try payload.encode(to: encoder)
        case .status(let payload):
            try container.encode(TypeName.status.rawValue, forKey: .type)
            try payload.encode(to: encoder)
        case .attachment(let payload):
            try container.encode(TypeName.attachment.rawValue, forKey: .type)
            try payload.encode(to: encoder)
        case .unsupported(let payload):
            try container.encode(payload.rawType, forKey: .type)
        }
    }
}
