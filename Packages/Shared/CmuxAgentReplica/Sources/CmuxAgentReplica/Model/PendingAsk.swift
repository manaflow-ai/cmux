import Foundation

/// Records one question or permission ask awaiting user disposition.
public struct PendingAsk: Codable, Hashable, Sendable, Identifiable {
    /// The stable ask identifier.
    public let id: String
    /// The session this ask belongs to.
    public let sessionID: AgentSessionID
    /// The ask kind.
    public let kind: PendingAskKind
    /// The prompt summary suitable for compact display.
    public let promptSummary: String
    /// The number of available choices.
    public let optionsCount: Int
    /// The ask state.
    public let state: PendingAskState

    /// Creates a pending ask.
    /// - Parameters:
    ///   - id: The stable ask identifier.
    ///   - sessionID: The owning session identifier.
    ///   - kind: The ask kind.
    ///   - promptSummary: The compact prompt summary.
    ///   - optionsCount: The number of choices.
    ///   - state: The ask state.
    public init(
        id: String,
        sessionID: AgentSessionID,
        kind: PendingAskKind,
        promptSummary: String,
        optionsCount: Int,
        state: PendingAskState
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.promptSummary = promptSummary
        self.optionsCount = optionsCount
        self.state = state
    }
}
