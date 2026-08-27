import Foundation

/// The live activity state of an agent session.
///
/// Drives the typing indicator and the session header dot. This is
/// transient presence, not transcript content; it never becomes a
/// ``ChatMessage`` row.
public enum ChatAgentState: Sendable, Equatable {
    /// The agent is idle, awaiting input.
    case idle
    /// The agent has been working since the associated time.
    case working(since: Date)
    /// The agent is blocked on the user (question or permission) since the
    /// associated time.
    case needsInput(since: Date)
    /// The agent process ended.
    case ended

    /// Whether the user's attention is required.
    public var needsAttention: Bool {
        if case .needsInput = self { return true }
        return false
    }
}

extension ChatAgentState: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case since
    }

    private enum StateName: String {
        case idle
        case working
        case needsInput = "needs_input"
        case ended
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .state)
        switch StateName(rawValue: raw) {
        case .idle:
            self = .idle
        case .working:
            self = .working(since: try container.decode(Date.self, forKey: .since))
        case .needsInput:
            self = .needsInput(since: try container.decode(Date.self, forKey: .since))
        case .ended:
            self = .ended
        case .none:
            self = .idle
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode(StateName.idle.rawValue, forKey: .state)
        case .working(let since):
            try container.encode(StateName.working.rawValue, forKey: .state)
            try container.encode(since, forKey: .since)
        case .needsInput(let since):
            try container.encode(StateName.needsInput.rawValue, forKey: .state)
            try container.encode(since, forKey: .since)
        case .ended:
            try container.encode(StateName.ended.rawValue, forKey: .state)
        }
    }
}
