import Foundation

/// Bounded, demand-driven buffer between an attach connection's reader
/// thread and the terminal view that consumes `events`.
///
/// Backpressure: once armed (after the attach response), the reader thread
/// blocks while more than `highWater` output bytes wait, and resumes below
/// `lowWater`. The socket then stops draining, so the daemon's bounded attach
/// mailbox overflows and it ends the stream with `overflow` instead of the
/// app buffering without limit; the view reattaches from a fresh replay.
/// Replays never block (a 10 MiB replay must not wedge the attach
/// handshake). Consecutive plain output chunks are merged on the way out.
final class TerminalEventQueue: @unchecked Sendable {
    /// What a push did on a queue whose reader must not wait.
    enum PushOutcome: Equatable {
        case queued
        /// Output passed `highWater`: every queued output chunk and history
        /// page was dropped (the new one too). The stream resyncs by snapshot.
        case overflowed
    }

    let highWater: Int
    let lowWater: Int
    let mergeLimit: Int
    /// False on a shared connection (`attach-streams-v1`): the reader thread
    /// serves every stream and the control plane, so it never waits; a
    /// consumer that falls `highWater` behind loses its queued output instead
    /// and its stream resyncs by snapshot (D5).
    let blocksReader: Bool
    /// Called on the reader thread, with the lock held, each time a `push`
    /// starts to block above `highWater`. Tests use it to observe
    /// backpressure without timing; it must not block or touch the queue.
    private let onReaderBlocked: (@Sendable () -> Void)?

    // All mutable state is guarded by `condition`.
    private let condition = NSCondition()
    private var items: [TerminalChannelEvent] = []
    private var head = 0
    private var outputBytes = 0
    private var waiter: CheckedContinuation<TerminalChannelEvent?, Never>?
    private var finished = false
    private var armed = false

    init(highWater: Int = 8 << 20, lowWater: Int = 2 << 20, mergeLimit: Int = 1 << 20,
         blocksReader: Bool = true, onReaderBlocked: (@Sendable () -> Void)? = nil) {
        self.blocksReader = blocksReader
        self.highWater = highWater
        self.lowWater = lowWater
        self.mergeLimit = mergeLimit
        self.onReaderBlocked = onReaderBlocked
    }

    /// The queue of a view on a shared connection (`attach-streams-v1`): the
    /// reader never waits, and chunks are not merged, so each frame and ring
    /// span stays its own event (a ring span reaches Ghostty uncopied and no
    /// bytes move past a grid change).
    static func sharedConnection() -> TerminalEventQueue {
        TerminalEventQueue(mergeLimit: 0, blocksReader: false)
    }

    /// Enables blocking once the consumer can start draining.
    func arm() {
        condition.lock()
        armed = true
        condition.unlock()
    }

    /// Reader thread. May block while the consumer is behind (only when
    /// ``blocksReader``).
    @discardableResult
    func push(_ event: TerminalChannelEvent) -> PushOutcome {
        condition.lock()
        guard !finished else {
            condition.unlock()
            return .queued
        }
        if let waiter {
            self.waiter = nil
            condition.unlock()
            waiter.resume(returning: event)
            return .queued
        }
        items.append(event)
        outputBytes += Self.outputSize(event)
        if !blocksReader {
            defer { condition.unlock() }
            guard outputBytes > highWater else { return .queued }
            dropQueuedOutput()
            return .overflowed
        }
        if armed, !finished, outputBytes > highWater { onReaderBlocked?() }
        while armed, !finished, outputBytes > highWater {
            // concurrency-allow: runs only on the attach connection's dedicated reader thread (LineTransport), never the main thread; this is the designed backpressure that makes the daemon drop a slow view.
            condition.wait()
        }
        condition.unlock()
        return .queued
    }

    /// Drops every queued output chunk and history page; other events stay
    /// in order. Caller holds the lock.
    private func dropQueuedOutput() {
        let kept = items.dropFirst(head).filter { Self.outputSize($0) == 0 }
        items = Array(kept)
        head = 0
        outputBytes = 0
    }

    /// Any thread. Queues a small, non-output event without the backpressure wait, so a caller may
    /// hold its own lock across it (a size state is pushed under the lock that orders generations).
    func pushWithoutWaiting(_ event: TerminalChannelEvent) {
        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            condition.unlock()
            waiter.resume(returning: event)
            return
        }
        items.append(event)
        outputBytes += Self.outputSize(event)
        condition.unlock()
    }

    /// Ends the stream after `last` (if any) and anything already queued.
    /// Unblocks a waiting reader.
    func finish(_ last: TerminalChannelEvent? = nil) {
        condition.lock()
        guard !finished else {
            condition.unlock()
            return
        }
        finished = true
        condition.broadcast()
        if let waiter {
            self.waiter = nil
            condition.unlock()
            waiter.resume(returning: last)
            return
        }
        if let last { items.append(last) }
        condition.unlock()
    }

    /// Consumer drops the stream: discard everything and release the reader.
    func cancel() {
        condition.lock()
        finished = true
        items.removeAll()
        head = 0
        outputBytes = 0
        condition.broadcast()
        let waiter = self.waiter
        self.waiter = nil
        condition.unlock()
        waiter?.resume(returning: nil)
    }

    /// Next event, merging consecutive plain output chunks up to `mergeLimit`.
    func next() async -> TerminalChannelEvent? {
        await withCheckedContinuation { continuation in
            takeOrWait(continuation)
        }
    }

    /// Resumes at once when an event is queued or the stream ended;
    /// otherwise parks the continuation for the next `push`/`finish`.
    private func takeOrWait(_ continuation: CheckedContinuation<TerminalChannelEvent?, Never>) {
        condition.lock()
        if let event = popMerged() {
            condition.unlock()
            continuation.resume(returning: event)
        } else if finished {
            condition.unlock()
            continuation.resume(returning: nil)
        } else {
            waiter = continuation
            condition.unlock()
        }
    }

    var bufferedOutputBytes: Int {
        condition.lock()
        defer { condition.unlock() }
        return outputBytes
    }

    // Caller holds the lock.
    /// Nil when no event is queued.
    private func popMerged() -> TerminalChannelEvent? {
        guard var event = items[checked: head] else { return nil }
        head += 1
        if case .output(var data, nil) = event {
            while data.count < mergeLimit, case .output(let more, nil)? = items[checked: head] {
                data.append(more)
                head += 1
            }
            event = .output(data, colors: nil)
            outputBytes -= data.count
        } else {
            outputBytes -= Self.outputSize(event)
        }
        if head > 256, head * 2 > items.count {
            items.removeFirst(head)
            head = 0
        }
        if outputBytes <= lowWater { condition.broadcast() }
        return event
    }

    /// Bulk bytes: output and snapshot history. A READY, like a replay,
    /// never blocks the reader (it is one screen, sent before the attach
    /// reply on attach).
    private static func outputSize(_ event: TerminalChannelEvent) -> Int {
        switch event {
        case .output(let data, _): data.count
        case .snapshot(let frame) where frame.phase != .ready: frame.data.count
        default: 0
        }
    }
}
