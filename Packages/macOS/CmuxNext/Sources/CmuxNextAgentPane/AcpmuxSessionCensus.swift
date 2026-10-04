import Foundation

/// The local acpmux daemon's agents, counted from `_acpmux/sessions` for the
/// quit dialog (plans/cmux-next/quit-persistence.md 4.1): how many agents
/// keep running after the app quits and how many are in a turn now.
public nonisolated struct AcpmuxSessionCensus: Sendable, Equatable {
    /// Sessions with a running agent process (`ready`, `running`, `waiting`).
    public var live: Int
    /// Sessions in a turn (`running`, or `waiting` for a permission answer).
    public var inTurn: Int
    /// Titles (else names, else ids) of the sessions in a turn, oldest turn first.
    public var inTurnNames: [String]
    /// A Home Chief session is in a turn. Chief sessions are never counted
    /// above (and never ended by a quit).
    public var chiefInTurn: Bool

    /// The tag key on every Home Chief turn and compactor session (value:
    /// the home id), agreed with the chief lane. Untagged Chief sessions are
    /// known by `chiefNamePrefix` and `chiefCompactorPresetPrefix`.
    public static let chiefTagKey = "cmux.chief"
    public static let chiefNamePrefix = "optchat-"
    public static let chiefCompactorPresetPrefix = "optchat-compact-"

    public init(live: Int = 0, inTurn: Int = 0, inTurnNames: [String] = [], chiefInTurn: Bool = false) {
        self.live = live
        self.inTurn = inTurn
        self.inTurnNames = inTurnNames
        self.chiefInTurn = chiefInTurn
    }

    /// The census of one `_acpmux/sessions` result.
    public static func parse(_ result: [String: Any]) -> AcpmuxSessionCensus {
        AcpmuxSessionCensus()
    }
}
