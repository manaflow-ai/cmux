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
    let highWater: Int
    let lowWater: Int
    let mergeLimit: Int
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
         onReaderBlocked: (@Sendable () -> Void)? = nil) {
        self.highWater = highWater
        self.lowWater = lowWater
        self.mergeLimit = mergeLimit
        self.onReaderBlocked = onReaderBlocked
    }

    /// Enables blocking once the consumer can start draining.
    func arm() {
        condition.lock()
        armed = true
        condition.unlock()
    }

    /// Reader thread. May block while the consumer is behind.
    func push(_ event: TerminalChannelEvent) {
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
        if armed, !finished, outputBytes > highWater { onReaderBlocked?() }
        while armed, !finished, outputBytes > highWater {
            // concurrency-allow: runs only on the attach connection's dedicated reader thread (LineTransport), never the main thread; this is the designed backpressure that makes the daemon drop a slow view.
            condition.wait()
        }
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
        if head < items.count {
            let event = popMerged()
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
    private func popMerged() -> TerminalChannelEvent {
        var event = items[head]
        head += 1
        if case .output(var data, nil) = event {
            while head < items.count, data.count < mergeLimit, case .output(let more, nil) = items[head] {
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
        case .snapshot(let frame) where frame.phase == .history: frame.data.count
        default: 0
        }
    }
}
