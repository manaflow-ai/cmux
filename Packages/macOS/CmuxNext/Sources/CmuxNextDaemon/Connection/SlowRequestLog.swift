import CmuxNextCompat
import Darwin
public import Foundation
import os

/// The app side of the slow request log: one JSON line for each daemon request the app waited more
/// than 100 ms for (send to reply), each request that timed out, got an error reply or lost its
/// connection, and each optimistic change (a store intent) that was rolled back. Always on: no
/// setting turns it off.
///
/// The lines go to `slow-requests-app.jsonl` (+ `.1`, each at most 1 MiB, mode 0600) in the daemon's
/// session folder, beside the daemon's own `slow-requests.jsonl` (same format, `"side":"daemon"`),
/// and one notice line each to the unified log (subsystem `com.cmuxterm.app.next`, category
/// `slow-requests`).
///
/// Cost: the request path does one comparison for a fast request. A record is put on a bounded queue
/// (``queueLimit`` entries; a full queue drops the record and counts it, it never waits) and one
/// serial utility queue renders and writes it. Nothing is written while no record is made.
///
/// Privacy: a line holds a command or operation name, numeric ids and public ids
/// (`<prefix>_<32 hex>`) of the keys in ``idKeys``, durations, sizes and an error code. Never a
/// request's other params, a reply's contents or an error message (``render(_:)``).
public final class SlowRequestLog: Sendable {
    /// A request the app waited longer than this for gets a record.
    public static let slowNanoseconds: UInt64 = 100_000_000
    /// The most bytes of the file and of its one rotated copy (`.1`), each.
    public static let maxFileBytes = 1 << 20
    public static let fileName = "slow-requests-app.jsonl"
    /// The most records that wait for the writer; more are dropped and counted.
    static let queueLimit = 256
    /// A request line longer than this is not kept for its ids (the record has none): the queue's
    /// memory stays below `queueLimit * maxKeptLineBytes`.
    static let maxKeptLineBytes = 16 << 10

    private struct State {
        var queue: [Entry] = []
        var droppedSinceWrite: UInt64 = 0
        var droppedTotal: UInt64 = 0
        var draining = false
        var directory: URL?
    }

    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "slow-requests")

    private let state = Mutex(State())
    private let writerQueue = DispatchQueue(label: "com.cmuxterm.next.daemon.slow-log", qos: .utility)
    /// The monotonic clock of the request probe (`CLOCK_UPTIME_RAW`, nanoseconds): the transport and
    /// the store stamp with it. Tests inject one.
    let uptime: @Sendable () -> UInt64
    private let wallMilliseconds: @Sendable () -> UInt64
    private let emit: @Sendable (String) -> Void

    /// The app's log: the uptime clock, the wall clock and the unified log.
    public convenience init() {
        self.init(uptime: { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
                  wallMilliseconds: {
                      var now = timespec()
                      clock_gettime(CLOCK_REALTIME, &now)
                      return UInt64(truncatingIfNeeded: now.tv_sec) &* 1000 &+ UInt64(truncatingIfNeeded: now.tv_nsec) / 1_000_000
                  },
                  emit: { line in SlowRequestLog.logger.notice("\(line, privacy: .public)") })
    }

    /// - Parameters:
    ///   - uptime: Monotonic nanoseconds.
    ///   - wallMilliseconds: Milliseconds since 1970 (UTC), read once per record.
    ///   - emit: Gets each line on the writer queue, before the file does (the unified log).
    init(uptime: @escaping @Sendable () -> UInt64, wallMilliseconds: @escaping @Sendable () -> UInt64,
         emit: @escaping @Sendable (String) -> Void) {
        self.uptime = uptime
        self.wallMilliseconds = wallMilliseconds
        self.emit = emit
    }

    /// The folder the file is written in. Records made before the first call wait in the bounded queue.
    /// The folder is never created here: a missing one gets no file.
    public func setDirectory(_ directory: URL) {
        let start = state.withLock { state -> Bool in
            state.directory = directory
            guard !state.draining, !state.queue.isEmpty else { return false }
            state.draining = true
            return true
        }
        if start { writerQueue.async { [self] in drain() } }
    }

    /// Records dropped since launch because the queue was full.
    var droppedCount: UInt64 { state.withLock { $0.droppedTotal } }

    /// Returns once the writer wrote every record made before the call.
    func flushed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async { continuation.resume() }
        }
    }

    /// One request ended after `nanoseconds`: a record when it was slow or failed. `line` is the
    /// request as sent, read only on the writer queue and only for the ids in ``idKeys``.
    func noteRequest(name: String, line: Data?, nanoseconds: UInt64, replyBytes: Int?, timeout: Duration?, failure: (any Error)?) {
        var outcome = Outcome.ok
        var code: String?
        if let failure {
            // A request that was never sent (it could not be encoded, it names a pane still opening) is no request.
            guard let failed = Failure(failure) else { return }
            outcome = failed.outcome
            code = failed.code
        } else if nanoseconds <= Self.slowNanoseconds {
            return
        }
        var timeoutMilliseconds: Int64?
        if let timeout {
            let parts = timeout.components
            timeoutMilliseconds = parts.seconds &* 1000 &+ parts.attoseconds / 1_000_000_000_000_000
        }
        enqueue(.request(RequestEntry(name: name, line: line, atMilliseconds: wallMilliseconds(), nanoseconds: nanoseconds,
                                      replyBytes: replyBytes, timeoutMilliseconds: timeoutMilliseconds, outcome: outcome, error: code)))
    }

    /// An optimistic change was rolled back. `startedAt` is ``uptime`` when it was shown (0: not known).
    func noteRollback(name: String, startedAt: UInt64, failure: (any Error)?) {
        var code: String?
        if let failure {
            let failed = Failure(failure)
            switch failed?.outcome {
            case .some(.timedOut): code = Outcome.timedOut.rawValue
            case .some(.connectionLost): code = Outcome.connectionLost.rawValue
            default: code = failed?.code ?? Self.unknownErrorCode
            }
        }
        enqueue(.rollback(RollbackEntry(name: name, atMilliseconds: wallMilliseconds(),
                                        nanoseconds: startedAt == 0 ? nil : uptime() &- startedAt, error: code)))
    }

    /// Never waits: a full queue drops the record and counts it.
    private func enqueue(_ entry: Entry) {
        let start = state.withLock { state -> Bool in
            guard state.queue.count < Self.queueLimit else {
                state.droppedSinceWrite &+= 1
                state.droppedTotal &+= 1
                return false
            }
            state.queue.append(entry)
            guard !state.draining, state.directory != nil else { return false }
            state.draining = true
            return true
        }
        if start { writerQueue.async { [self] in drain() } }
    }

    /// On the writer queue: writes every queued record, then a `dropped` record when records were dropped.
    /// It ends when the queue is empty: the next record starts it again.
    private func drain() {
        while let taken = takeBatch() {
            // The queue was full with these records when the drops came: the count goes after them, before the next record.
            var lines = taken.entries.map { Self.render($0) }
            if taken.dropped > 0 { lines.append(Self.renderDropped(taken.dropped, atMilliseconds: wallMilliseconds())) }
            for line in lines {
                emit(line)
                SlowRequestLogFile(directory: taken.directory).append(line)
            }
        }
    }

    /// The queued records and the drop count, taken in one lock; nil (and the drain is over) when there are none.
    private func takeBatch() -> Batch? {
        state.withLock { state -> Batch? in
            guard let directory = state.directory, !state.queue.isEmpty else {
                state.draining = false
                return nil
            }
            let batch = Batch(entries: state.queue, dropped: state.droppedSinceWrite, directory: directory)
            state.queue.removeAll(keepingCapacity: true)
            state.droppedSinceWrite = 0
            return batch
        }
    }

    private struct Batch: Sendable {
        var entries: [Entry]
        var dropped: UInt64
        var directory: URL
    }
}
