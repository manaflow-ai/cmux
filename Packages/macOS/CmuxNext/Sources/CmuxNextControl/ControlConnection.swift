import CmuxNextCompat
import CmuxNextSettings
import CmuxNextTrace
import CmuxNextWakeups
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation
import Darwin
import Foundation

/// One accepted client. All socket IO runs on a private serial queue at
/// utility QoS (automation; the main hop keeps the method's `MainWorkClass`):
/// nonblocking reads split lines for a single consumer task, and responses
/// go through a nonblocking, capped write buffer, so a slow or stuck client
/// can only stall its own connection.
///
/// Bounds (architecture.md 5a, "no unbounded buffers"):
/// - inbound: at most `maxQueuedLines` parsed lines, and `maxQueuedBytes` of
///   them (one line of any size up to `maxLineBytes` always passes), wait for
///   the consumer; beyond that the read source is suspended and the kernel
///   socket buffer pushes back on the client.
/// - outbound: at most `maxOutboxBytes` of unsent responses; a client that
///   stops reading past that is disconnected.
/// - close: queued responses get `drainTimeout` to flush after `close()`.
///
/// Hang watch: the queue is one hang-watched lane and each job on it (a source handler or a posted
/// block, each one ``withState(_:_:)``) is one scope: ``readHangDeadline``, or ``writeHangDeadline`` for a
/// job that sends. Every call in a job is non-blocking, so a job past its budget is a bug.
final class ControlConnection: Sendable {
    struct Limits: Sendable {
        var maxLineBytes: Int
        var maxQueuedLines = 64
        /// The line bytes waiting for the consumer past which reading pauses.
        var maxQueuedBytes = 8 << 20
        var maxOutboxBytes = 8 << 20
        var drainTimeout: Duration = .seconds(5)
    }

    let id: ControlConnectionID
    private let descriptor: Int32
    private let limits: Limits
    private let queue: DispatchQueue
    /// The queue's hang-watch lane and the watch it is registered on; nil watches nothing.
    private let hangWatched: (watch: any HangWatchScoping, lane: HangWatch.Registration)?
    /// The budget of a job that reads or keeps state (a jank past it, a hang dump 2 s later).
    static let readHangDeadline: Duration = .seconds(1)
    /// The budget of a job that sends.
    static let writeHangDeadline: Duration = .seconds(2)
    /// Only blocks on `queue` touch the state (``withState(_:_:)``), so its lock is never contended: it makes the
    /// queue's confinement checked.
    private let state: Mutex<State>

    private struct State {
        var readSource: (any DispatchSourceRead)?
        var writeSource: (any DispatchSourceWrite)?
        var drainTimer: DemandTimer?
        var liveSources = 0
        var inbound = Data()
        var queuedLines = 0
        /// The byte size of each queued line, oldest first (at most `maxQueuedLines`), and their sum.
        var queuedLineSizes: [Int] = []
        var queuedBytes = 0
        var isReadSuspended = false
        var isInputFinished = false
        var outbox = Data()
        var outboxOffset = 0
        var isWriteArmed = false
        var isCloseRequested = false
        var isClosed = false
        var isDescriptorClosed = false
        var continuation: AsyncStream<String>.Continuation?
        var consumer: Task<Void, Never>?
        var hangupWaiters: [OnceContinuation<Void, OnceContinuationError>] = []
        /// Called once on the connection queue after the descriptor closed.
        var onClosed: (@Sendable () -> Void)?
    }

    /// - Parameters:
    ///   - hangs: Watches each job on the connection queue; nil watches nothing.
    ///   - onClosed: Called once on the connection queue after the descriptor closed.
    init(id: ControlConnectionID, descriptor: Int32, limits: Limits, hangs: (any HangWatchScoping)? = nil,
         onClosed: (@Sendable () -> Void)? = nil) {
        self.id = id
        self.descriptor = descriptor
        self.limits = limits
        self.queue = DispatchQueue(label: "com.cmuxterm.next.control.\(id)", qos: .utility)
        hangWatched = hangs.map { (watch: $0, lane: $0.registerLane("control.connection")) }
        var initial = State()
        initial.onClosed = onClosed
        self.state = Mutex(initial)
    }

    deinit {
        if let hangWatched { hangWatched.watch.unregister(hangWatched.lane) }
    }

    /// The connection queue's QoS (tests).
    var queueQoS: DispatchQoS.QoSClass { queue.qos.qosClass }

    /// The line bytes handed to the consumer that it has not finished (tests).
    var queuedLineBytes: Int { state.withLock(\.queuedBytes) }

    func start(consume: @escaping @Sendable (AsyncStream<String>) async -> Void) {
        // The stream never exceeds `maxQueuedLines` or `maxQueuedBytes`: reading pauses first.
        // concurrency-allow: bounded by maxQueuedLines; the read source suspends before the stream exceeds it
        // memory: bounded-by maxQueuedBytes (8 MiB, or one line up to maxLineBytes): the read source suspends at it
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        queue.async { [self] in
            withState { state in
                state.continuation = continuation
                let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    withState { self.readAvailable(&$0) }
                }
                source.setCancelHandler { [weak self] in
                    guard let self else { return }
                    withState { self.sourceCancelled(&$0) }
                }
                state.readSource = source
                state.liveSources += 1
                source.resume()
                state.consumer = Task { await consume(stream) }
            }
        }
    }

    /// Queues one response line. Never blocks the caller.
    func send(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { [self] in
            withState(Self.writeHangDeadline) { state in
                guard !state.isClosed else { return }
                if state.outbox.count - state.outboxOffset + data.count > limits.maxOutboxBytes {
                    // The client stopped reading; drop it rather than buffer without limit.
                    closeNow(&state)
                    return
                }
                state.outbox.append(data)
                flush(&state)
            }
        }
    }

    /// Returns once the client stopped sending (EOF, error) or the
    /// connection closed (a failed write to a gone client closes it). A waiter dropped unresumed returns too.
    func hangup() async {
        _ = try? await withOnceContinuation { (waiter: OnceContinuation<Void, OnceContinuationError>) in
            queue.async { [self] in
                withState { state in
                    if state.isInputFinished || state.isClosed { waiter.resume(returning: ()) } else { state.hangupWaiters.append(waiter) }
                }
            }
        }
    }

    /// The consumer finished one line; reading may resume.
    func lineConsumed() {
        queue.async { [self] in
            withState { state in
                state.queuedLines = max(0, state.queuedLines - 1)
                if !state.queuedLineSizes.isEmpty { state.queuedBytes -= state.queuedLineSizes.removeFirst() }
                emitLines(&state)
                if state.isReadSuspended, !state.isInputFinished, !isQueueFull(state), !state.isClosed {
                    state.isReadSuspended = false
                    state.readSource?.resume()
                }
            }
        }
    }

    /// Stops reading and closes once queued responses flushed (or after
    /// `drainTimeout`).
    func close() {
        queue.async { [self] in
            withState { state in
                guard !state.isClosed, !state.isCloseRequested else { return }
                state.isCloseRequested = true
                finishInput(&state)
                if state.outboxOffset >= state.outbox.count {
                    closeNow(&state)
                    return
                }
                // The drain deadline (5 s) after the client half-closes; cancelled by closeNow.
                let timer = DemandTimer(owner: "ControlConnection.drain")
                timer.schedule(after: limits.drainTimeout) { [weak self] in self?.drainDeadlinePassed() }
                state.drainTimer = timer
            }
        }
    }

    // MARK: - Queue-confined

    /// On the connection queue, as one whole job: runs `body` with the state, then `onClosed` (outside the
    /// lock) when the descriptor closed in it, both in one hang-watch scope of `deadline`. Never called from
    /// inside `body`: the lock is not recursive.
    private func withState(_ deadline: Duration = ControlConnection.readHangDeadline, _ body: (inout State) -> Void) {
        guard let hangWatched else { return runJob(body) }
        hangWatched.watch.watch(hangWatched.lane, deadline: deadline) { runJob(body) }
    }

    private func runJob(_ body: (inout State) -> Void) {
        let closed = state.withLock { state -> (@Sendable () -> Void)? in
            body(&state)
            return state.isDescriptorClosed ? state.onClosed.take() : nil
        }
        closed?()
    }

    private func resumeHangupWaiters(_ state: inout State) {
        let waiters = state.hangupWaiters
        state.hangupWaiters.removeAll()
        waiters.forEach { $0.resume(returning: ()) }
    }

    private func readAvailable(_ state: inout State) {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !state.isReadSuspended, !state.isInputFinished {
            // SAFETY: read writes at most chunk.count bytes into the array's own storage, lent for the call.
            let count = unsafe read(descriptor, &chunk, chunk.count)
            if count > 0 {
                state.inbound.append(contentsOf: chunk.prefix(count))
                emitLines(&state)
                if state.inbound.count > limits.maxLineBytes, state.inbound.firstIndex(of: 0x0A) == nil {
                    let error = ControlError(code: "request_too_large", message: ControlStrings.format("control.error.requestTooLarge", "Request line exceeds %lld bytes", limits.maxLineBytes))
                    state.outbox.append(Data((ControlWire.encode(id: nil, error: error) + "\n").utf8))
                    flush(&state)
                    finishInput(&state)
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            // EOF or error: the consumer drains what it has, then closes.
            finishInput(&state)
            return
        }
    }

    /// True when the consumer holds `maxQueuedLines` lines or, with at least one, `maxQueuedBytes`.
    private func isQueueFull(_ state: State) -> Bool {
        state.queuedLines >= limits.maxQueuedLines || (state.queuedLines > 0 && state.queuedBytes >= limits.maxQueuedBytes)
    }

    /// Hands complete lines to the consumer until `maxQueuedLines` or
    /// `maxQueuedBytes` wait, then suspends reading.
    private func emitLines(_ state: inout State) {
        while !isQueueFull(state), let newline = state.inbound.firstIndex(of: 0x0A) {
            let lineData = state.inbound.prefix(upTo: newline)
            state.inbound.removeSubrange(state.inbound.startIndex...newline)
            state.queuedLines += 1
            state.queuedLineSizes.append(lineData.count)
            state.queuedBytes += lineData.count
            state.continuation?.yield(String(decoding: lineData, as: UTF8.self))
        }
        if state.isInputFinished, state.inbound.firstIndex(of: 0x0A) == nil {
            state.continuation?.finish()
            state.continuation = nil
        }
        if isQueueFull(state), !state.isReadSuspended, !state.isInputFinished, let readSource = state.readSource {
            readSource.suspend()
            state.isReadSuspended = true
        }
    }

    /// Stops reading (EOF, error, oversized line, close) but keeps the
    /// descriptor open so queued responses still reach a half-closed client.
    private func finishInput(_ state: inout State) {
        guard !state.isInputFinished else { return }
        state.isInputFinished = true
        resumeHangupWaiters(&state)
        if let readSource = state.readSource, !state.isReadSuspended {
            readSource.suspend()
            state.isReadSuspended = true
        }
        // Lines already buffered still reach the consumer (see emitLines).
        emitLines(&state)
    }

    private func flush(_ state: inout State) {
        while state.outboxOffset < state.outbox.count {
            let offset = state.outboxOffset
            // SAFETY: `raw` is the outbox's contiguous storage, valid only inside this closure, which never lets a
            // pointer out; 0 <= offset < raw.count (the loop's condition), so the send covers the raw.count - offset
            // bytes from base + offset to the buffer's end.
            let written = unsafe state.outbox.withUnsafeBytes { raw -> Int in
                // The loop runs only while the outbox has bytes, so the base address is set;
                // without one the send fails like a closed peer (no trap).
                guard let base = unsafe raw.baseAddress else { errno = EPIPE; return -1 }
                return unsafe Darwin.send(descriptor, base + offset, raw.count - offset, MSG_NOSIGNAL)
            }
            if written > 0 {
                state.outboxOffset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            if written < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                armWriteSource(&state)
                return
            }
            // EPIPE/ECONNRESET: the client went away (MSG_NOSIGNAL and the
            // server's SO_NOSIGPIPE keep that from raising SIGPIPE).
            closeNow(&state)
            return
        }
        state.outbox.removeAll(keepingCapacity: state.outbox.count <= 64 * 1024)
        state.outboxOffset = 0
        if state.isWriteArmed {
            state.writeSource?.suspend()
            state.isWriteArmed = false
        }
        if state.isCloseRequested { closeNow(&state) }
    }

    private func armWriteSource(_ state: inout State) {
        if state.outboxOffset > 1 << 20, state.outboxOffset * 2 > state.outbox.count {
            state.outbox.removeSubrange(0..<state.outboxOffset)
            state.outboxOffset = 0
        }
        guard !state.isWriteArmed else { return }
        if state.writeSource == nil {
            let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                withState(Self.writeHangDeadline) { self.flush(&$0) }
            }
            source.setCancelHandler { [weak self] in
                guard let self else { return }
                withState { self.sourceCancelled(&$0) }
            }
            state.writeSource = source
            state.liveSources += 1
        }
        state.isWriteArmed = true
        state.writeSource?.resume()
    }

    /// The drain deadline fired off the queue: close on it (a no-op when already closed).
    private func drainDeadlinePassed() {
        queue.async { [self] in
            withState { closeNow(&$0) }
        }
    }

    private func closeNow(_ state: inout State) {
        guard !state.isClosed else { return }
        state.isClosed = true
        state.isInputFinished = true
        resumeHangupWaiters(&state)
        state.continuation?.finish()
        state.continuation = nil
        state.drainTimer?.cancel()
        state.drainTimer = nil
        state.outbox = Data()
        state.outboxOffset = 0
        // A suspended source must be resumed before its cancel handler runs.
        if let readSource = state.readSource {
            if state.isReadSuspended { readSource.resume() }
            readSource.cancel()
        }
        if let writeSource = state.writeSource {
            if !state.isWriteArmed { writeSource.resume() }
            writeSource.cancel()
        }
        state.readSource = nil
        state.writeSource = nil
        if state.liveSources == 0 { closeDescriptor(&state) }
    }

    private func sourceCancelled(_ state: inout State) {
        state.liveSources -= 1
        if state.liveSources == 0, state.isClosed { closeDescriptor(&state) }
    }

    /// Closes the descriptor; ``withState(_:_:)`` then calls `onClosed`.
    private func closeDescriptor(_ state: inout State) {
        Darwin.close(descriptor)
        state.isDescriptorClosed = true
    }
}
