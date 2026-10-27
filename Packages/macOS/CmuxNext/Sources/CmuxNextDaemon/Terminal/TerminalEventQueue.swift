import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Foundation

/// Bounded, demand-driven buffer between an attach reader thread and the
/// terminal view that consumes `events`. What happens once the consumer falls
/// more than `highWater` output bytes behind depends on ``Backpressure``:
///
/// - ``Backpressure/parkReader`` (the legacy per-view attach connection): the
///   reader thread blocks until the consumer drains to `lowWater`. The socket
///   then stops draining, so the daemon's bounded attach mailbox overflows and
///   it ends the stream with `overflow`; the view reattaches from a fresh replay.
/// - ``Backpressure/dropAndResync(onResync:)`` (a stream on the shared
///   connection): the reader never waits, so a stopped view cannot delay
///   another stream or a control reply on that connection. The queue drops the
///   output a fresh READY supersedes, asks once for that READY and drops such
///   output until it arrives, as ``StreamDemux``'s sinks do (Chrome's
///   `MultiplexRouter` never blocks its IO thread on one endpoint,
///   `mojo/public/cpp/bindings/lib/multiplex_router.cc`).
///
/// Both bounds apply only once armed (after the attach reply): a replay or a
/// READY's history (up to 32 MiB) is the handshake itself and must not wedge or
/// resync it. Consecutive plain output chunks are merged on the way out.
final class TerminalEventQueue: Sendable {
    /// What a push does once the consumer is `highWater` output bytes behind.
    enum Backpressure: Sendable {
        /// Park the reader thread until the consumer drains to `lowWater` (the per-view connection).
        case parkReader
        /// Never wait. Drop the queued output a fresh READY supersedes and drop such output until that
        /// READY; `onResync` runs once per overflow on the reader thread, outside the queue's lock, and
        /// must not block (it enqueues the `snapshot-request`). A byte attach has no READY to ask for,
        /// so it ends with `closed(.overflow)` instead and the view reattaches.
        case dropAndResync(onResync: @Sendable () -> Void)
    }

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
    private let backpressure: Backpressure
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
        /// `dropAndResync` only: an overflow asked for a READY; output it supersedes is dropped until then.
        var resyncing = false
        /// A READY was queued: a snapshot attach, which resyncs in place.
        var snapshotAttach = false
        var overflows = 0
        var droppedEvents = 0

        /// Whether the reader must wait now (armed, not finished, above `highWater`); marks it parked if so.
        mutating func parkReader(above highWater: Int) -> Bool {
            readerParked = armed && !finished && outputBytes > highWater
            return readerParked
        }

        /// Clears the parked mark; true when the caller must signal the reader.
        mutating func releaseReader() -> Bool {
            defer { readerParked = false }
            return readerParked
        }

        /// Whether `event` is dropped because the READY a resync asked for supersedes it. A READY (or a
        /// replay) ends the resync and is queued.
        mutating func dropWhileResyncing(_ event: TerminalChannelEvent) -> Bool {
            guard resyncing else { return false }
            if TerminalEventQueue.startsFreshState(event) {
                resyncing = false
                return false
            }
            guard TerminalEventQueue.isSupersededByReady(event) else { return false }
            droppedEvents += 1
            return true
        }

        /// Whether queuing `bulk` more bytes overflows. An item is admitted when no bulk is queued even
        /// if it alone is larger, so one oversized chunk cannot resync forever.
        func overflows(adding bulk: Int, highWater: Int) -> Bool {
            armed && bulk > 0 && outputBytes > 0 && outputBytes + bulk > highWater
        }

        /// Drops every queued event a fresh READY supersedes; size, color and scroll states stay in order.
        mutating func dropSuperseded() {
            let kept = items.dropFirst(head).filter { !TerminalEventQueue.isSupersededByReady($0) }
            droppedEvents += items.count - head - kept.count
            items = Array(kept)
            head = 0
            outputBytes = 0
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

    /// What a push that never waits did with its event.
    private enum Admission: Sendable {
        case queuedOrDropped
        case handed(OnceContinuation<TerminalChannelEvent?, OnceContinuationError>)
        /// A snapshot attach overflowed: the owner asks for a READY.
        case resync
    }

    init(highWater: Int = 8 << 20, lowWater: Int = 2 << 20, mergeLimit: Int = 1 << 20,
         backpressure: Backpressure = .parkReader,
         recorder: DaemonWireStats.Recorder?, onReaderBlocked: (@Sendable () -> Void)? = nil) {
        self.highWater = highWater
        self.lowWater = lowWater
        self.mergeLimit = mergeLimit
        self.backpressure = backpressure
        self.recorder = recorder
        self.onReaderBlocked = onReaderBlocked
    }

    /// Enables the bound once the consumer can start draining.
    func arm() {
        state.withLock { $0.armed = true }
    }

    /// Reader thread. With ``Backpressure/parkReader`` it may block while the consumer is behind;
    /// with ``Backpressure/dropAndResync(onResync:)`` it never waits.
    func push(_ event: TerminalChannelEvent) {
        switch backpressure {
        case .parkReader: pushParkingReader(event)
        case .dropAndResync(let onResync): pushDroppingOnOverflow(event, onResync: onResync)
        }
    }

    private func pushParkingReader(_ event: TerminalChannelEvent) {
        let (waiter, blocked) = state.withLock { state -> (OnceContinuation<TerminalChannelEvent?, OnceContinuationError>?, Bool) in
            guard !state.finished else { return (nil, false) }
            if let waiter = state.waiter.take() { return (waiter, false) }
            state.items.append(event)
            state.outputBytes += Self.outputSize(event)
            return (nil, state.parkReader(above: highWater))
        }
        waiter?.resume(returning: event)
        guard blocked else { return }
        onReaderBlocked?()
        var parked = blocked
        while parked {
            // The designed backpressure that makes the daemon drop a slow view: a checked wait, only on the attach
            // connection's dedicated reader thread (LineTransport), never the main thread or a pool thread.
            readerWake.blockingWait()
            parked = state.withLock { $0.parkReader(above: highWater) }
        }
    }

    private func pushDroppingOnOverflow(_ event: TerminalChannelEvent, onResync: @Sendable () -> Void) {
        let admission = state.withLock { state -> Admission in
            guard !state.finished, !state.dropWhileResyncing(event) else { return .queuedOrDropped }
            if case .snapshot(let frame) = event, frame.phase == .ready { state.snapshotAttach = true }
            let bulk = Self.outputSize(event)
            if state.overflows(adding: bulk, highWater: highWater) {
                state.overflows += 1
                state.dropSuperseded()
                state.droppedEvents += 1
                guard state.snapshotAttach else {
                    // A byte attach has no READY to ask for: end the stream, and the view reattaches.
                    state.finished = true
                    state.items.append(.closed(.overflow))
                    return .queuedOrDropped
                }
                state.resyncing = true
                return .resync
            }
            if let waiter = state.waiter.take() { return .handed(waiter) }
            state.items.append(event)
            state.outputBytes += bulk
            return .queuedOrDropped
        }
        switch admission {
        case .queuedOrDropped: break
        case .handed(let waiter): waiter.resume(returning: event)
        case .resync: onResync()
        }
    }

    /// Any thread. Queues a small, non-output event without the backpressure wait, so a caller may
    /// hold its own lock across it (a size state is pushed under the lock that orders generations).
    /// While a resync waits for its READY, an event that READY supersedes (the echo of dropped output)
    /// is dropped.
    func pushWithoutWaiting(_ event: TerminalChannelEvent) {
        let waiter = state.withLock { state -> OnceContinuation<TerminalChannelEvent?, OnceContinuationError>? in
            guard !state.finished, !state.dropWhileResyncing(event) else { return nil }
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

    /// Overflows so far (``Backpressure/dropAndResync(onResync:)``); each resynced or ended the stream once.
    var overflowCount: Int {
        state.withLock { $0.overflows }
    }

    /// Events dropped by overflows and while a resync waited for its READY.
    var droppedEventCount: Int {
        state.withLock { $0.droppedEvents }
    }

    /// True between an overflow of a snapshot attach and its READY.
    var isResyncing: Bool {
        state.withLock { $0.resyncing }
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

    /// A full terminal state the view applies in place of what it had: a READY or a replay.
    private static func startsFreshState(_ event: TerminalChannelEvent) -> Bool {
        switch event {
        case .snapshot(let frame): frame.phase == .ready
        case .replay, .resized: true
        default: false
        }
    }

    /// Terminal content a later READY replaces: output, its echo marks and older snapshots. Size, color and
    /// scroll states and the end of the stream are kept, in order.
    private static func isSupersededByReady(_ event: TerminalChannelEvent) -> Bool {
        switch event {
        case .output, .inputEcho, .snapshot, .replay, .resized: true
        case .colorsChanged, .scrollChanged, .sizeState, .closed: false
        }
    }
}
