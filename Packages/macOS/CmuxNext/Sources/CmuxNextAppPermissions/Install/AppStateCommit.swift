/// The result of one accepted op. Wire shape: `{"outcome": "applied", "events": [...]}`.
public nonisolated struct AppStateCommit: Sendable, Hashable, Codable {
    public enum Outcome: String, Sendable, Hashable, Codable {
        /// The record changed.
        case applied
        /// Valid, but nothing to change (hide an already hidden app).
        case noChange = "no_change"
        /// A replay of an earlier key: no further effect.
        case replayed
        /// Remove of a default-installed app without confirmation: hidden instead.
        case convertedToHide = "converted_to_hide"
    }

    public var outcome: Outcome
    public var events: [AppStateEvent]

    public init(outcome: Outcome, events: [AppStateEvent]) {
        self.outcome = outcome
        self.events = events
    }
}

/// An accepted op kept for replay, under its client's key.
public nonisolated struct AppStateReceipt: Sendable, Hashable, Codable {
    public var op: AppStateOp
    public var commit: AppStateCommit
}
