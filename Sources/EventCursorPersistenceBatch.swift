import Foundation

struct EventCursorPersistenceBatch {
    private let maximumPendingEvents: Int
    private let maximumDelay: Duration
    private let write: (Int64) throws -> Void

    private var pendingSequence: Int64?
    private var pendingEventCount = 0
    private var batchStartedAt: ContinuousClock.Instant?

    init(
        maximumPendingEvents: Int = 128,
        maximumDelay: Duration = .seconds(1),
        write: @escaping (Int64) throws -> Void
    ) {
        precondition(maximumPendingEvents > 0)
        precondition(maximumDelay > .zero)
        self.maximumPendingEvents = maximumPendingEvents
        self.maximumDelay = maximumDelay
        self.write = write
    }

    mutating func record(_ sequence: Int64, now: ContinuousClock.Instant) throws {
        if pendingSequence == nil {
            batchStartedAt = now
        }
        pendingSequence = sequence
        pendingEventCount += 1
        try flushIfDue(now: now)
    }

    mutating func flushIfDue(now: ContinuousClock.Instant) throws {
        guard pendingSequence != nil else { return }
        let reachedEventLimit = pendingEventCount >= maximumPendingEvents
        let reachedTimeLimit = batchStartedAt.map { $0.duration(to: now) >= maximumDelay } ?? false
        guard reachedEventLimit || reachedTimeLimit else { return }
        try flush(now: now)
    }

    mutating func flush(now _: ContinuousClock.Instant) throws {
        guard let pendingSequence else { return }
        try write(pendingSequence)
        self.pendingSequence = nil
        pendingEventCount = 0
        batchStartedAt = nil
    }
}
