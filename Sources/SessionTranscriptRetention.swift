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

/// Bounded ring buffer used while streaming a potentially large transcript.
struct SessionTranscriptLatestCollector: Sendable {
    private let capacity: Int
    private var openingUser: SessionTranscriptTurn?
    private var storage: [SessionTranscriptTurn] = []
    private var replacementIndex = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    mutating func append(_ turn: SessionTranscriptTurn) {
        if openingUser == nil, turn.role == .user {
            openingUser = turn
        }
        if storage.count < capacity {
            storage.append(turn)
            return
        }
        storage[replacementIndex] = turn
        replacementIndex = (replacementIndex + 1) % capacity
    }

    var turns: [SessionTranscriptTurn] {
        let ordered: [SessionTranscriptTurn]
        if storage.count < capacity || replacementIndex == 0 {
            ordered = storage
        } else {
            ordered = Array(storage[replacementIndex...]) + Array(storage[..<replacementIndex])
        }
        guard let openingUser,
              !ordered.contains(where: { $0.id == openingUser.id }) else {
            return ordered
        }
        return [openingUser] + Array(ordered.suffix(max(0, capacity - 1)))
    }
}
