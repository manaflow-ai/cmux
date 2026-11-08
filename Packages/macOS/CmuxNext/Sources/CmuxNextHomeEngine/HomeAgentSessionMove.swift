/// One acpmux session's move (`acpmux session move`), from its summary: where it went and its move epoch.
nonisolated struct HomeAgentSessionMove: Hashable, Sendable {
    /// `movedTo.host`: the machine it went to; nil when the record names none.
    var place: String?
    /// `moveEpoch`: raised by every move; 0 when it never moved.
    var moveEpoch: UInt64
}
