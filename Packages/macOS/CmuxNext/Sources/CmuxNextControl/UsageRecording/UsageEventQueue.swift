import CmuxNextCompat
import Foundation
import os

/// The events waiting for one `usage-record` call. ``stage(_:)`` is a short lock from any thread
/// (the main actor's focus changes, the action reporter's task), so recording an event starts no
/// task and awaits nothing; the sends run on this actor. A batch goes to the daemon when
/// ``flushThreshold`` events wait, and on ``flush()`` (the app resigning active, quitting). No
/// timers. One send is on its way at a time; what is staged meanwhile waits, at most ``capacity``
/// events (the oldest go first), so a daemon that does not answer never grows it.
///
/// ```swift
/// let queue = UsageEventQueue { events in try await send(UsageRecordRequest(source: "app-nightly", events: events)) }
/// queue.stage([UsageRecord(at: UsageRecord.nowMilliseconds(), event: .active(on: true))])
/// await queue.flush()
/// ```
actor UsageEventQueue {
    /// Events that send a batch on their own.
    static let flushThreshold = 64
    /// The most events kept while sends fail.
    static let capacity = 1024

    /// Sends one batch's events text (a JSON array); throws when it was not recorded.
    typealias Send = @Sendable (String) async throws -> Void

    private struct Waiting {
        var records: [UsageRecord] = []
        /// Off: nothing is kept (recording was turned off, maybe while a batch was on its way).
        var isOn = true
        /// The count that sends the next batch on its own: ``flushThreshold``, or that many more than
        /// a failed send kept, so a daemon that is down is not asked again on every event.
        var nextAutoFlush = UsageEventQueue.flushThreshold
        /// A send was started for the count reached and has not taken the records yet.
        var flushQueued = false
        /// A batch is on its way to the daemon.
        var sending = false
        /// A ``flush()`` came while a batch was on its way: what waits goes right after it.
        var flushAgain = false

        /// The records of the next send, or nil when there are none or one is on its way.
        mutating func take() -> [UsageRecord]? {
            guard isOn, !sending, !records.isEmpty else { return nil }
            sending = true
            flushAgain = false
            defer { records.removeAll(keepingCapacity: true) }
            return records
        }

        mutating func keep(_ more: [UsageRecord], atFront: Bool = false) {
            records = atFront ? more + records : records + more
            if records.count > UsageEventQueue.capacity { records.removeFirst(records.count - UsageEventQueue.capacity) }
        }
    }

    private let send: Send
    private let waiting = Mutex(Waiting())
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "usage-recording")

    init(send: @escaping Send) {
        self.send = send
    }

    /// The events waiting now (tests).
    nonisolated var count: Int { waiting.withLock { $0.records.count } }

    /// Keeps `records` for the next batch, from any thread; reaching the count starts its send.
    nonisolated func stage(_ records: [UsageRecord]) {
        guard !records.isEmpty else { return }
        let full = waiting.withLock { waiting -> Bool in
            guard waiting.isOn else { return false }
            waiting.keep(records)
            guard waiting.records.count >= waiting.nextAutoFlush, !waiting.flushQueued else { return false }
            waiting.flushQueued = true
            return true
        }
        guard full else { return }
        // task-owner: one send of the batch that reached the count; it ends when the daemon answers.
        Task { await self.flush() }
    }

    /// Sends what waits as one batch. A failed send keeps it for the next flush. While a batch is on
    /// its way this sends nothing itself: the batch's answer sends what waits next.
    func flush() async {
        var next = waiting.withLock { waiting -> [UsageRecord]? in
            // While a batch is on its way, the auto flush stays queued: its answer clears it.
            if waiting.sending {
                waiting.flushAgain = true
                return nil
            }
            waiting.flushQueued = false
            return waiting.take()
        }
        while let batch = next {
            do {
                try await send(try UsageRecord.batch(batch))
                waiting.withLock { $0.nextAutoFlush = Self.flushThreshold }
            } catch {
                logger.error("usage-record not sent: \(String(describing: error), privacy: .public)")
                waiting.withLock { waiting in
                    guard waiting.isOn else { return }
                    waiting.keep(batch, atFront: true)
                    waiting.nextAutoFlush = min(waiting.records.count, Self.capacity - Self.flushThreshold) + Self.flushThreshold
                }
            }
            next = waiting.withLock { waiting -> [UsageRecord]? in
                waiting.sending = false
                waiting.flushQueued = false
                guard waiting.flushAgain || waiting.records.count >= waiting.nextAutoFlush else { return nil }
                return waiting.take()
            }
        }
    }

    /// Recording stopped: drops what waits, and everything staged from now on.
    nonisolated func stop() {
        waiting.withLock { waiting in
            waiting.isOn = false
            waiting.records.removeAll()
        }
    }
}
