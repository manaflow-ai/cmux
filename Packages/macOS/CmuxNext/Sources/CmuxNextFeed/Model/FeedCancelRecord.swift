public import Foundation

/// Why and by whom a request closed without an answer.
public nonisolated struct FeedCancelRecord: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        case poster
        case declined
        case answeredElsewhere = "answered_elsewhere"
        case superseded
        case posterGone = "poster_gone"
    }

    public var reason: Reason
    public var by: String
    public var at: Date
    public var note: String?

    public init(reason: Reason, by: String, at: Date, note: String? = nil) {
        self.reason = reason
        self.by = by
        self.at = at
        self.note = note
    }
}
