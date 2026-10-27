import CmuxNextCompat
import CmuxNextWakeups
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
/// - ``Backpressure/dropAndResync(_:)`` (a stream on the shared connection):
///   the reader never waits, so a stopped view cannot delay another stream or a
///   control reply on that connection. The queue drops the output a fresh READY
///   supersedes, asks for that READY and drops such output until it arrives, as
///   ``StreamDemux``'s sinks do (Chrome's `MultiplexRouter` never blocks its IO
///   thread on one endpoint, `mojo/public/cpp/bindings/lib/multiplex_router.cc`).
///   At most one request is out: while a READY waits for the consumer, an
///   overflow drops only the output after it, and the request goes out when the
///   consumer takes that READY. A throttled request is sent again after the
///   daemon's delay; a failed one ends the stream with `closed(.overflow)`.
///
/// Both bounds apply only once armed (after the attach reply): a replay is the
/// handshake itself and must not wedge it. The resync bound counts live output
/// only, never a READY's history (up to 32 MiB: the answer to a resync, a resize
/// or the attach). Consecutive plain output chunks are merged on the way out.
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
    private let backpressure: Backpressure
    /// Sends a throttled request again (``Backpressure/dropAndResync(_:)`` only).
    private let retryTimer: DemandTimer?
    private let state = Mutex(State())
    // concurrency-allow: the designed backpressure that makes the daemon drop a slow view: only the attach
    // connection's dedicated reader thread (LineTransport) waits on it, never the main thread or a pool thread.
    private let readerWake = DispatchSemaphore(value: 0)

    /// What a push that never waits did with its event.
    private enum Admission: Sendable {
        case queuedOrDropped
        case handed(OnceContinuation<TerminalChannelEvent?, OnceContinuationError>)
        /// A snapshot attach overflowed with no READY queued: send the request of `epoch`.
        case resync(epoch: UInt64)
    }

    /// - Parameter clock: What the retry of a throttled resync sleeps on; tests pass a `ManualClock`.
    init(highWater: Int = 8 << 20, lowWater: Int = 2 << 20, mergeLimit: Int = 1 << 20,
         backpressure: Backpressure = .parkReader, clock: any Clock<Duration> = ContinuousClock(),
         recorder: DaemonWireStats.Recorder?, onReaderBlocked: (@Sendable () -> Void)? = nil) {
        self.highWater = highWater
        self.lowWater = lowWater
        self.mergeLimit = mergeLimit
        self.backpressure = backpressure
        if case .dropAndResync = backpressure {
            retryTimer = DemandTimer(owner: "TerminalEventQueue.resync", clock: clock)
        } else {
            retryTimer = nil
        }
        self.recorder = recorder
        self.onReaderBlocked = onReaderBlocked
    }

    /// Enables the bound once the consumer can start draining.
    func arm() {
        state.withLock { $0.armed = true }
    }

    /// Reader thread. With ``Backpressure/parkReader`` it may block while the consumer is behind;
    /// with ``Backpressure/dropAndResync(_:)`` it never waits.
    func push(_ event: TerminalChannelEvent) {
        switch backpressure {
        case .parkReader: pushParkingReader(event)
        case .dropAndResync: pushDroppingOnOverflow(event)
        }
    }

    private func pushParkingReader(_ event: TerminalChannelEvent) {
        let (waiter, blocked) = state.withLock { state -> (OnceContinuation<TerminalChannelEvent?, OnceContinuationError>?, Bool) in
            guard !state.finished else { return (nil, false) }
            if let waiter = state.waiter.take() { return (waiter, false) }
            state.append(event)
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

    private func pushDroppingOnOverflow(_ event: TerminalChannelEvent) {
        let admission = state.withLock { state -> Admission in
            guard !state.finished, !state.dropWhileResyncing(event) else { return .queuedOrDropped }
            if case .snapshot(let frame) = event, frame.phase == .ready { state.snapshotAttach = true }
            if state.overflows(adding: Self.liveOutputSize(event), highWater: highWater) {
                state.overflows += 1
                state.droppedEvents += 1
                guard state.snapshotAttach else {
                    // A byte attach has no READY to ask for: end the stream, and the view reattaches.
                    state.dropSuperseded()
                    state.finished = true
                    state.items.append(.closed(.overflow))
                    return .queuedOrDropped
                }
                guard state.queuedFreshStates == 0 else {
                    // The consumer has not taken the last READY: no second request until it does.
                    state.keepNewestFreshState()
                    state.resync = .deferred
                    return .queuedOrDropped
                }
                state.dropSuperseded()
                return .resync(epoch: state.beginResync())
            }
            if let waiter = state.waiter.take() { return .handed(waiter) }
            state.append(event)
            return .queuedOrDropped
        }
        switch admission {
        case .queuedOrDropped: break
        case .handed(let waiter): waiter.resume(returning: event)
        case .resync(let epoch): sendResync(epoch: epoch)
        }
    }

    /// Sends the request of `epoch`, outside the queue's lock; its answer comes back to
    /// ``resyncAnswered(_:epoch:)``.
    private func sendResync(epoch: UInt64) {
        guard case .dropAndResync(let request) = backpressure else { return }
        request { [weak self] outcome in self?.resyncAnswered(outcome, epoch: epoch) }
    }

    /// Any thread. A throttled request goes out again after the daemon's delay; a failed one ends the
    /// stream with `closed(.overflow)`, so the attach machine reattaches. An answer to an older
    /// request, or to one a fresh state already answered, changes nothing.
    private func resyncAnswered(_ outcome: ResyncOutcome, epoch: UInt64) {
        switch outcome {
        case .accepted:
            return
        case .throttled(let delay):
            guard state.withLock({ $0.awaitsReady(epoch: epoch) }) else { return }
            retryTimer?.schedule(after: delay) { [weak self] in self?.retryResync(epoch: epoch) }
        case .failed:
            end(with: .closed(.overflow)) { $0.awaitsReady(epoch: epoch) }
        }
    }

    private func retryResync(epoch: UInt64) {
        let retry = state.withLock { state -> Bool in
            guard state.awaitsReady(epoch: epoch) else { return false }
            state.resyncRequests += 1
            return true
        }
        if retry { sendResync(epoch: epoch) }
    }

    /// Any thread. Queues a small, non-output event without the backpressure wait, so a caller may
    /// hold its own lock across it (a size state is pushed under the lock that orders generations).
    /// While a resync waits for its READY, an event that READY supersedes (the echo of dropped output)
    /// is dropped.
    func pushWithoutWaiting(_ event: TerminalChannelEvent) {
        let waiter = state.withLock { state -> OnceContinuation<TerminalChannelEvent?, OnceContinuationError>? in
            guard !state.finished, !state.dropWhileResyncing(event) else { return nil }
            if let waiter = state.waiter.take() { return waiter }
            state.append(event)
            return nil
        }
        waiter?.resume(returning: event)
    }

    /// Ends the stream after `last` (if any) and anything already queued.
    /// Unblocks a waiting reader.
    func finish(_ last: TerminalChannelEvent? = nil) {
        end(with: last) { _ in true }
    }

    /// ``finish(_:)`` when `condition` holds under the queue's lock.
    private func end(with last: TerminalChannelEvent?, if condition: (State) -> Bool) {
        let (ended, waiter, release) = state.withLock {
            state -> (Bool, OnceContinuation<TerminalChannelEvent?, OnceContinuationError>?, Bool) in
            guard !state.finished, condition(state) else { return (false, nil, false) }
            state.finished = true
            let release = state.releaseReader()
            if let waiter = state.waiter.take() { return (true, waiter, release) }
            if let last { state.items.append(last) }
            return (true, nil, release)
        }
        guard ended else { return }
        retryTimer?.cancel()
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
            state.liveOutputBytes = 0
            state.queuedFreshStates = 0
            return (state.waiter.take(), state.releaseReader())
        }
        retryTimer?.cancel()
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
        let (ready, release, resync) = state.withLock { state -> (TerminalChannelEvent??, Bool, UInt64?) in
            if let event = state.popMerged(mergeLimit: mergeLimit, recorder: recorder) {
                let resync = state.takeDeferredResync()
                // At or below `lowWater` the reader reads again.
                guard state.outputBytes <= lowWater else { return (.some(event), false, resync) }
                return (.some(event), state.releaseReader(), resync)
            }
            if state.finished { return (.some(nil), false, nil) }
            state.waiter = continuation
            return (nil, false, nil)
        }
        if release { readerWake.signal() }
        if let resync { sendResync(epoch: resync) }
        if let ready { continuation.resume(returning: ready) }
    }

    var bufferedOutputBytes: Int {
        state.withLock { $0.outputBytes }
    }

    /// Overflows so far (``Backpressure/dropAndResync(_:)``); each one resynced, deferred a resync
    /// or ended the stream.
    var overflowCount: Int {
        state.withLock { $0.overflows }
    }

    /// `snapshot-request`s sent so far, the retries of a throttled one included.
    var resyncRequestCount: Int {
        state.withLock { $0.resyncRequests }
    }

    /// Events dropped by overflows and while a resync waited for its READY.
    var droppedEventCount: Int {
        state.withLock { $0.droppedEvents }
    }

    var resyncPhase: ResyncPhase {
        state.withLock { $0.resync }
    }
}
