import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
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
///
/// Live output that goes straight to the view's lane (``TerminalEchoRouter``)
/// parks the same reader on the lane's capacity instead (``waitForLane(_:)``), and
/// output the router holds behind a marker parks it on the router's hold limit
/// (``holdForMarker()``).
final class TerminalEventQueue: Sendable {
    let highWater: Int
    let lowWater: Int
    let mergeLimit: Int
    /// Called on the reader thread each time a `push` starts to block above
    /// `highWater`, before it waits. Tests use it to observe backpressure
    /// without timing; it must not block.
    private let onReaderBlocked: (@Sendable () -> Void)?
    /// Counts the output bytes the queue copies when it merges chunks
    /// (``DaemonWireStats/Snapshot/outputBytesCopiedApp``); nil counts nothing.
    private let recorder: DaemonWireStats.Recorder?
    private let state = Mutex(State())
    // concurrency-allow: the designed backpressure that makes the daemon drop a slow view: only the attach
    // connection's dedicated reader thread (LineTransport) waits on it, never the main thread or a pool thread.
    private let readerWake = DispatchSemaphore(value: 0)

    private struct State {
        var items: [TerminalChannelEvent] = []
        var head = 0
        var outputBytes = 0
        var waiter: OnceContinuation<TerminalChannelEvent?, OnceContinuationError>?
        var finished = false
        var armed = false
        /// The reader waits on `readerWake`; whoever clears this signals it exactly once.
        var readerParked = false
        /// The view's lane is above its capacity: the reader waits until the lane wakes it (``releaseLane(closing:)``).
        var laneHeld = false
        /// Output held behind a marker is above the router's hold limit: the reader waits until the marker is
        /// acknowledged (``releaseMarkerHold()``).
        var markerHeld = false
        /// The link detached: neither the lane nor a marker holds the reader again.
        var laneClosed = false

        /// Whether the reader must wait now (not finished, and the lane or a marker holds it or the queue is armed
        /// and above `highWater`); marks it parked if so.
        mutating func parkReader(above highWater: Int) -> Bool {
            readerParked = !finished && (laneHeld || markerHeld || (armed && outputBytes > highWater))
            return readerParked
        }

        /// Clears the parked mark; true when the caller must signal the reader.
        mutating func releaseReader() -> Bool {
            defer { readerParked = false }
            return readerParked
        }

        /// Next event, merging consecutive plain output chunks up to `mergeLimit`; nil when none is queued.
        mutating func popMerged(mergeLimit: Int, recorder: DaemonWireStats.Recorder?) -> TerminalChannelEvent? {
            guard var event = items[checked: head] else { return nil }
            head += 1
            if case .output(var data, nil) = event {
                var merged = false
                while data.count < mergeLimit, case .output(let more, nil)? = items[checked: head] {
                    data.append(more)
                    head += 1
                    merged = true
                }
                // A merge writes every byte of the result into a new buffer.
                if merged { recorder?.outputCopied(data.count) }
                event = .output(data, colors: nil)
                outputBytes -= data.count
            } else {
                outputBytes -= TerminalEventQueue.outputSize(event)
            }
            if head > 256, head * 2 > items.count {
                items.removeFirst(head)
                head = 0
            }
            return event
        }
    }

    init(highWater: Int = 8 << 20, lowWater: Int = 2 << 20, mergeLimit: Int = 1 << 20,
         recorder: DaemonWireStats.Recorder?, onReaderBlocked: (@Sendable () -> Void)? = nil) {
        self.highWater = highWater
        self.lowWater = lowWater
        self.mergeLimit = mergeLimit
        self.recorder = recorder
        self.onReaderBlocked = onReaderBlocked
    }

    /// Enables blocking once the consumer can start draining.
    func arm() {
        state.withLock { $0.armed = true }
    }

    /// Reader thread. May block while the consumer is behind.
    func push(_ event: TerminalChannelEvent) {
        pushWithoutWaiting(event)
        waitWhileFull()
    }

    /// Reader thread: waits while the consumer is behind (armed and above `highWater`). Returns at once otherwise.
    func waitWhileFull() {
        guard state.withLock({ $0.parkReader(above: highWater) }) else { return }
        onReaderBlocked?()
        parkReader()
    }

    /// Reader thread: hands one live chunk to the view's lane (`enqueue`, given the lane's wake) and, when the
    /// lane says it is above its capacity, waits until the lane wakes it, the stream ends or the link detaches
    /// (``releaseLane()``). `enqueue` returns whether the reader must wait; the lane calls the wake exactly once
    /// when it returned true.
    func waitForLane(_ enqueue: (_ wake: @escaping @Sendable () -> Void) -> Bool) {
        let holds = state.withLock { state -> Bool in
            state.laneHeld = !state.laneClosed
            return state.laneHeld
        }
        guard enqueue({ [self] in releaseLane() }), holds else {
            state.withLock { $0.laneHeld = false }
            return
        }
        guard state.withLock({ $0.parkReader(above: highWater) }) else { return }
        onReaderBlocked?()
        parkReader()
    }

    /// Any thread: the lane drained below its capacity or closed, or (`closing`) the link detached and neither
    /// the lane nor a marker holds the reader again; a reader waiting for the lane goes on.
    func releaseLane(closing: Bool = false) {
        let release = state.withLock { state -> Bool in
            state.laneHeld = false
            if closing {
                state.laneClosed = true
                state.markerHeld = false
            }
            return state.releaseReader()
        }
        if release { readerWake.signal() }
    }

    /// Under the router's lock: the output held behind a marker is above the router's hold limit, so the
    /// reader's next ``waitWhileFull()`` waits until ``releaseMarkerHold()``, which the router calls under the
    /// same lock: an acknowledgement is never missed, and an older one never releases a newer hold.
    func holdForMarker() {
        state.withLock { state in
            let closed = state.laneClosed
            state.markerHeld = !closed
        }
    }

    /// Under the router's lock: the marker the held output waited behind was acknowledged (the output went to
    /// the lane), or the output went onto the stream; a reader waiting on it goes on.
    func releaseMarkerHold() {
        let release = state.withLock { state -> Bool in
            state.markerHeld = false
            return state.releaseReader()
        }
        if release { readerWake.signal() }
    }

    /// Waits on `readerWake` until nothing holds the reader; ``State/parkReader(above:)`` marked it parked.
    private func parkReader() {
        var parked = true
        while parked {
            // The designed backpressure that makes the daemon drop a slow view: a checked wait, only on the attach
            // connection's dedicated reader thread (LineTransport), never the main thread or a pool thread.
            readerWake.blockingWait()
            parked = state.withLock { $0.parkReader(above: highWater) }
        }
    }

    /// Any thread. Queues a small, non-output event without the backpressure wait, so a caller may
    /// hold its own lock across it (a size state is pushed under the lock that orders generations).
    func pushWithoutWaiting(_ event: TerminalChannelEvent) {
        let waiter = state.withLock { state -> OnceContinuation<TerminalChannelEvent?, OnceContinuationError>? in
            guard !state.finished else { return nil }
            if let waiter = state.waiter.take() { return waiter }
            state.items.append(event)
            state.outputBytes += Self.outputSize(event)
            return nil
        }
        waiter?.resume(returning: event)
    }

    /// Ends the stream after `last` (if any) and anything already queued.
    /// Unblocks a waiting reader.
    func finish(_ last: TerminalChannelEvent? = nil) {
        let (waiter, release) = state.withLock { state -> (OnceContinuation<TerminalChannelEvent?, OnceContinuationError>?, Bool) in
            guard !state.finished else { return (nil, false) }
            state.finished = true
            let release = state.releaseReader()
            if let waiter = state.waiter.take() { return (waiter, release) }
            if let last { state.items.append(last) }
            return (nil, release)
        }
        if release { readerWake.signal() }
        waiter?.resume(returning: last)
    }

    /// Consumer drops the stream: discard everything and release the reader.
    func cancel() {
        let (waiter, release) = state.withLock { state -> (OnceContinuation<TerminalChannelEvent?, OnceContinuationError>?, Bool) in
            state.finished = true
            state.items.removeAll()
            state.head = 0
            state.outputBytes = 0
            return (state.waiter.take(), state.releaseReader())
        }
        if release { readerWake.signal() }
        waiter?.resume(returning: nil)
    }

    /// Next event, merging consecutive plain output chunks up to `mergeLimit`; nil once the stream ended,
    /// or when the parked waiter was dropped unresumed.
    func next() async -> TerminalChannelEvent? {
        try? await withOnceContinuation { (continuation: OnceContinuation<TerminalChannelEvent?, OnceContinuationError>) in
            takeOrWait(continuation)
        }
    }

    /// Resumes at once when an event is queued or the stream ended;
    /// otherwise parks the continuation for the next `push`/`finish`.
    private func takeOrWait(_ continuation: OnceContinuation<TerminalChannelEvent?, OnceContinuationError>) {
        let (ready, release) = state.withLock { state -> (TerminalChannelEvent??, Bool) in
            if let event = state.popMerged(mergeLimit: mergeLimit, recorder: recorder) {
                // At or below `lowWater` the reader reads again.
                guard state.outputBytes <= lowWater else { return (.some(event), false) }
                return (.some(event), state.releaseReader())
            }
            if state.finished { return (.some(nil), false) }
            state.waiter = continuation
            return (nil, false)
        }
        if release { readerWake.signal() }
        if let ready { continuation.resume(returning: ready) }
    }

    var bufferedOutputBytes: Int {
        state.withLock { $0.outputBytes }
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
