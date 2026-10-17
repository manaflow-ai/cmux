public import Foundation

/// The command body executed against a managed provider session.
public enum ConversationCommand: Codable, Hashable, Sendable {
    /// Starts a new provider turn immediately.
    case startTurn(text: String, model: String?, effort: String?)
    /// Queues text behind the active turn.
    case queue(text: String)
    /// Edits a queued item and returns its replacement draft when cancelled.
    case editQueued(itemID: ConversationItemID, text: String)
    /// Cancels a queued item.
    case cancelQueued(itemID: ConversationItemID)
    /// Sends a steering message to the active turn.
    case steer(text: String)
    /// Interrupts the active provider turn.
    case interrupt
    /// Answers a provider question.
    case answerQuestion(requestID: ConversationRequestID, answers: [ConversationQuestionAnswer])
    /// Resolves an approval request.
    case resolveApproval(requestID: ConversationRequestID, decision: ConversationApprovalDecision)
    /// Renames a task.
    case rename(title: String)
    /// Pins or unpins a task.
    case setPinned(Bool)
    /// Archives or restores a task.
    case setArchived(Bool)
    /// Changes model/effort settings for future turns.
    case configure(model: String?, effort: String?, speed: String?)

    private enum CodingKeys: String, CodingKey { case kind, text, model, effort, itemID, requestID, optionID, answers, decision, title, value, speed }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "start": self = .startTurn(text: try c.decode(String.self, forKey: .text), model: try c.decodeIfPresent(String.self, forKey: .model), effort: try c.decodeIfPresent(String.self, forKey: .effort))
        case "queue": self = .queue(text: try c.decode(String.self, forKey: .text))
        case "edit-queued": self = .editQueued(itemID: try c.decode(ConversationItemID.self, forKey: .itemID), text: try c.decode(String.self, forKey: .text))
        case "cancel-queued": self = .cancelQueued(itemID: try c.decode(ConversationItemID.self, forKey: .itemID))
        case "steer": self = .steer(text: try c.decode(String.self, forKey: .text))
        case "interrupt": self = .interrupt
        case "answer-question": self = .answerQuestion(requestID: try c.decode(ConversationRequestID.self, forKey: .requestID), answers: try c.decode([ConversationQuestionAnswer].self, forKey: .answers))
        case "resolve-approval": self = .resolveApproval(requestID: try c.decode(ConversationRequestID.self, forKey: .requestID), decision: try c.decode(ConversationApprovalDecision.self, forKey: .decision))
        case "rename": self = .rename(title: try c.decode(String.self, forKey: .title))
        case "pinned": self = .setPinned(try c.decode(Bool.self, forKey: .value))
        case "archived": self = .setArchived(try c.decode(Bool.self, forKey: .value))
        case "configure": self = .configure(model: try c.decodeIfPresent(String.self, forKey: .model), effort: try c.decodeIfPresent(String.self, forKey: .effort), speed: try c.decodeIfPresent(String.self, forKey: .speed))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown conversation command")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .startTurn(let text, let model, let effort): try c.encode("start", forKey: .kind); try c.encode(text, forKey: .text); try c.encodeIfPresent(model, forKey: .model); try c.encodeIfPresent(effort, forKey: .effort)
        case .queue(let text): try c.encode("queue", forKey: .kind); try c.encode(text, forKey: .text)
        case .editQueued(let itemID, let text): try c.encode("edit-queued", forKey: .kind); try c.encode(itemID, forKey: .itemID); try c.encode(text, forKey: .text)
        case .cancelQueued(let itemID): try c.encode("cancel-queued", forKey: .kind); try c.encode(itemID, forKey: .itemID)
        case .steer(let text): try c.encode("steer", forKey: .kind); try c.encode(text, forKey: .text)
        case .interrupt: try c.encode("interrupt", forKey: .kind)
        case .answerQuestion(let requestID, let answers): try c.encode("answer-question", forKey: .kind); try c.encode(requestID, forKey: .requestID); try c.encode(answers, forKey: .answers)
        case .resolveApproval(let requestID, let decision): try c.encode("resolve-approval", forKey: .kind); try c.encode(requestID, forKey: .requestID); try c.encode(decision, forKey: .decision)
        case .rename(let title): try c.encode("rename", forKey: .kind); try c.encode(title, forKey: .title)
        case .setPinned(let value): try c.encode("pinned", forKey: .kind); try c.encode(value, forKey: .value)
        case .setArchived(let value): try c.encode("archived", forKey: .kind); try c.encode(value, forKey: .value)
        case .configure(let model, let effort, let speed): try c.encode("configure", forKey: .kind); try c.encodeIfPresent(model, forKey: .model); try c.encodeIfPresent(effort, forKey: .effort); try c.encodeIfPresent(speed, forKey: .speed)
        }
    }
}

/// An approval decision understood by provider-native protocols.
public enum ConversationApprovalDecision: String, Codable, Hashable, Sendable { case approve, alwaysApprove, deny }

/// A command envelope carrying generation and turn preconditions.
public struct ConversationCommandEnvelope: Codable, Hashable, Sendable {
    /// Durable command identity.
    public let commandID: ConversationCommandID
    /// Session receiving the command.
    public let sessionID: ConversationID
    /// Generation expected by the caller.
    public let expectedGeneration: ConversationGeneration?
    /// Active turn expected by the caller, when relevant.
    public let expectedTurnID: ConversationTurnID?
    /// Command body.
    public let command: ConversationCommand

    /// Creates a command envelope.
    public init(commandID: ConversationCommandID, sessionID: ConversationID, expectedGeneration: ConversationGeneration? = nil, expectedTurnID: ConversationTurnID? = nil, command: ConversationCommand) { self.commandID = commandID; self.sessionID = sessionID; self.expectedGeneration = expectedGeneration; self.expectedTurnID = expectedTurnID; self.command = command }
}
