/// Bounded ring buffer used while streaming a potentially large transcript.
struct SessionTranscriptLatestCollector: Sendable {
    private let retention: SessionTranscriptRetention
    private let capacity: Int
    private var openingUser: SessionTranscriptTurn?
    private var storage: [SessionTranscriptTurn?]
    private var oldestIndex = 0
    private var count = 0
    private var storedTextBytes = 0

    init(retention: SessionTranscriptRetention) {
        self.retention = retention
        capacity = retention.limit
        storage = Array(repeating: nil, count: retention.limit)
    }

    mutating func append(_ turn: SessionTranscriptTurn) {
        guard retention.includes(turn.role) else { return }
        let boundedTurn = retention.bounded(turn)
        if openingUser == nil, boundedTurn.role == .user {
            openingUser = boundedTurn
        }
        if count == capacity {
            removeOldest()
        }
        let insertionIndex = (oldestIndex + count) % capacity
        storage[insertionIndex] = boundedTurn
        count += 1
        storedTextBytes += retention.retainedByteCost(of: boundedTurn)
        if let textByteLimit = retention.textByteLimit {
            while count > 1, storedTextBytes > textByteLimit {
                removeOldest()
            }
        }
    }

    var turns: [SessionTranscriptTurn] {
        var ordered: [SessionTranscriptTurn] = []
        ordered.reserveCapacity(count)
        for offset in 0..<count {
            if let turn = storage[(oldestIndex + offset) % capacity] {
                ordered.append(turn)
            }
        }
        if let openingUser,
           !ordered.contains(where: { $0.id == openingUser.id }) {
            ordered = [openingUser] + Array(ordered.suffix(max(0, capacity - 1)))
        }
        return retention.boundedTurnsPreservingOpeningAndLatest(ordered)
    }

    private mutating func removeOldest() {
        guard count > 0, let removed = storage[oldestIndex] else { return }
        storedTextBytes -= retention.retainedByteCost(of: removed)
        storage[oldestIndex] = nil
        oldestIndex = (oldestIndex + 1) % capacity
        count -= 1
    }
}
