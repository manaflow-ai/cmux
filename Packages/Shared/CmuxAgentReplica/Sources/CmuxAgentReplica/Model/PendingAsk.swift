import Foundation

/// Records one question or permission ask awaiting user disposition.
public struct PendingAsk: Codable, Hashable, Sendable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case kind
        case promptSummary = "prompt_summary"
        case options
        case optionsCount = "options_count"
        case state
    }

    /// The stable ask identifier.
    public let id: String
    /// The session this ask belongs to.
    public let sessionID: AgentSessionID
    /// The ask kind.
    public let kind: PendingAskKind
    /// The prompt summary suitable for compact display.
    public let promptSummary: String
    /// Choice labels in runtime order. Empty means the terminal must answer.
    public let options: [String]
    /// The number of available choices retained for older wire peers.
    public let optionsCount: Int
    /// The ask state.
    public let state: PendingAskState

    /// Creates a pending ask.
    /// - Parameters:
    ///   - id: The stable ask identifier.
    ///   - sessionID: The owning session identifier.
    ///   - kind: The ask kind.
    ///   - promptSummary: The compact prompt summary.
    ///   - options: Choice labels in runtime order, or empty for terminal-only asks.
    ///   - state: The ask state.
    public init(
        id: String,
        sessionID: AgentSessionID,
        kind: PendingAskKind,
        promptSummary: String,
        options: [String],
        state: PendingAskState
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.promptSummary = promptSummary
        self.options = options
        self.optionsCount = options.count
        self.state = state
    }

    /// Decodes both current option labels and the prior count-only wire shape.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sessionID = try container.decode(AgentSessionID.self, forKey: .sessionID)
        kind = try container.decode(PendingAskKind.self, forKey: .kind)
        promptSummary = try container.decode(String.self, forKey: .promptSummary)
        options = try container.decodeIfPresent([String].self, forKey: .options) ?? []
        optionsCount = try container.decodeIfPresent(Int.self, forKey: .optionsCount) ?? options.count
        state = try container.decode(PendingAskState.self, forKey: .state)
    }
}
