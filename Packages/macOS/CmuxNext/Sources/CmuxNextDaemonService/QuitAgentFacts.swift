/// The local acpmux daemon's agent sessions, read for an interactive quit.
public struct QuitAgentFacts: Equatable, Sendable {
    /// Sessions with a running agent process (ready, running or waiting).
    public var live: Int
    /// Sessions in a turn (running, or waiting for a permission answer).
    public var inTurn: Int
    /// Titles (else names) of the sessions in a turn, at most `QuitRules.busiestLimit`.
    public var inTurnNames: [String]
    /// The Home Chief is in a turn. The Chief is never counted above and
    /// never ended by a quit; the dialog says it keeps running.
    public var chiefInTurn: Bool

    public init(live: Int, inTurn: Int, inTurnNames: [String], chiefInTurn: Bool = false) {
        self.live = live
        self.inTurn = inTurn
        self.inTurnNames = inTurnNames
        self.chiefInTurn = chiefInTurn
    }

    public static let zero = QuitAgentFacts(live: 0, inTurn: 0, inTurnNames: [])
}
