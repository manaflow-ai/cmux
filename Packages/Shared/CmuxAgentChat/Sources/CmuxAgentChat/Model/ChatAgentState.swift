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
    /// The most recent turn failed and can be retried by sending the same
    /// prompt again. This is distinct from ``ended``: the session remains
    /// attached to its terminal and accepts a retry or a new prompt.
    case failed(since: Date, reason: String?)
    /// The agent process ended.
    case ended

    /// Whether the user's attention is required.
    public var needsAttention: Bool {
        switch self {
        case .needsInput, .failed: return true
        case .idle, .working, .ended: return false
        }
    }

    /// Returns the state after accepted user input reaches the agent terminal.
    /// Hook events remain authoritative for subsequent transitions.
    public func afterExplicitInput(at: Date) -> Self {
        if case .needsInput = self {
            return .working(since: at)
        }
        if case .failed = self {
            return .working(since: at)
        }
        return self
    }
}

extension ChatAgentState: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case since
        case reason
    }

    private enum StateName: String {
        case idle
        case working
        case needsInput = "needs_input"
        case failed
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
        case .failed:
            self = .failed(
                since: try container.decode(Date.self, forKey: .since),
                reason: try container.decodeIfPresent(String.self, forKey: .reason)
            )
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
        case .failed(let since, let reason):
            try container.encode(StateName.failed.rawValue, forKey: .state)
            try container.encode(since, forKey: .since)
            try container.encodeIfPresent(reason, forKey: .reason)
        case .ended:
            try container.encode(StateName.ended.rawValue, forKey: .state)
        }
    }
}
