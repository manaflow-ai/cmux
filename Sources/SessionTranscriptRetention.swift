import Foundation

/// Selects which parsed transcript turns remain in memory.
enum SessionTranscriptRetention: Equatable, Sendable {
    /// Keep the first `limit` turns. Used by the Sessions preview.
    case prefix(Int)
    /// Keep the opening user request and the most recent `limit` turns.
    case openingUserAndLatest(Int)

    var limit: Int {
        switch self {
        case .prefix(let limit), .openingUserAndLatest(let limit):
            max(1, limit)
        }
    }

    var keepsLatestTurns: Bool {
        if case .openingUserAndLatest = self {
            return true
        }
        return false
    }
}
