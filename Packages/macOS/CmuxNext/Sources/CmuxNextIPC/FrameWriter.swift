import CmuxNextCompat
import Darwin
public import Dispatch
public import Foundation

/// Writes whole wire messages (JSON lines and 0xFF frames) to the daemon socket in priority order without ever
/// blocking the caller (plans/cmux-next/chrome-parity/p05-ipc.md, section 3.4 and task 055).
///
/// ``enqueue(_:priority:fds:)`` appends to one FIFO per ``MethodPriority`` and returns at once; one private serial
/// queue (`com.cmuxterm.next.daemon.write`, at the QoS the owner picks from the connection's role) drains them.
/// Each drain step takes the head of the highest non-empty FIFO, so a message never waits for more than the step
/// in flight: an input frame enqueued behind 8 MiB of bulk frames is the next message on the wire. Within one
/// priority the wire order is the call order. A message is never split by another: the producer cuts bulk at
/// BULK_FRAME_MAX with the MORE flag, and that cut is the preemption boundary (p05-ipc.md section 3.2).
///
/// This is the outgoing half of Chromium's `mojo/core/channel_posix.cc` (`outgoing_messages_`, written by
/// `WriteNoLock` / `FlushOutgoingMessagesNoLock` with the handles of a message on its first byte through
/// `SendmsgWithHandles`, mojo/public/cpp/platform/socket_utils_posix.cc), with the priority FIFOs of cmux-ipc's
/// LaneWriter (task 052) in place of Mojo's single queue. Waiting input and control messages leave together in one
/// send of at most ``batchBytes`` (Mojo's `kMaxBatchReadCapacity` analog on the write side), still in priority
/// order. A bulk or background message is always a drain step of its own, so the step in flight is never more than
/// one BULK_FRAME_MAX chunk of bulk.
///
/// Only the drain queue's thread waits on the socket. Past ``limit`` queued bytes ``enqueue(_:priority:fds:)``
/// fails with ``Failure/backlog(queued:)`` instead of buffering without bound.
///
/// Inline fast path (task 140): a caller off the main thread whose message the sink takes inline
/// (``FrameSink/takesInline(byteCount:fdCount:)``, its bytes and descriptors) and has nothing of its own or a higher
/// priority waiting, while no drain step is sending and no message is half sent, sends it itself with the sink's
/// ``FrameSink/trySend(_:fds:)``, under the writer's lock, and the drain queue is never woken. What the socket did
/// not take is the next drain step: none of it queues like any message, a tail goes before everything. This is
/// Mojo's `ChannelPosix::Write` (mojo/core/channel_posix.cc), which writes on the calling thread when
/// `outgoing_messages_` is empty and leaves only the rest to the IO thread. A main-thread caller always enqueues:
/// the main thread never makes a socket call.
public final class FrameWriter: Sendable {
    /// Why ``FrameWriter/enqueue(_:priority:fds:)`` refused a message.
    public enum Failure: Error, Equatable, Sendable, CustomStringConvertible {
        /// The other end closed the connection (EPIPE, ECONNRESET).
        case peerClosed
        /// The owner closed the writer.
        case closed
        /// The peer stopped reading and the queued bytes passed the limit.
        case backlog(queued: Int)
        /// A blocking send returned 0 (no progress).
        case noProgress
        /// A message asked to carry more than ``FrameWriter/maxFdsPerMessage`` descriptors.
        case tooManyFds(count: Int)
        /// A message with descriptors and no bytes: descriptors travel with a message's first byte.
        case fdsWithoutBytes
        case errno(Int32)

        public var description: String {
            switch self {
            case .peerClosed: "peer closed the socket"
            case .closed: "socket closed"
            case .backlog(let queued): "cmux-tui is not reading its socket (\(queued) bytes queued)"
            case .noProgress: "write: no progress"
            case .tooManyFds(let count): "a message carries \(count) descriptors, more than \(FrameWriter.maxFdsPerMessage)"
            case .fdsWithoutBytes: "a message carries descriptors and no bytes"
            case .errno(let code): "write: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Descriptors one message may carry (cmux-ipc fds.rs `MAX_FDS_PER_FRAME`; Chromium's
    /// base/posix/unix_domain_socket.cc caps a message the same way).
    public static let maxFdsPerMessage = 4
    /// The default bound on queued bytes (threading-model.md, daemon connection row: outbox 64 MiB).
    public static let defaultLimit = 64 << 20
    /// The most bytes one drain step gathers from several waiting input and control messages into one send.
    /// A single larger message is still sent whole; bulk and background messages are never gathered.
    public static let batchBytes = 64 << 10

    /// Runs one drain step (the send of one batch) on the drain queue and returns when `step` has run. The owner
    /// passes its hang-watch scope here (CmuxNextDaemon's `SocketWriter`), so this module needs no tracing.
    public typealias StepRunner = @Sendable (_ step: () -> Void) -> Void

    private let sink: any FrameSink
    private let limit: Int
    private let queue: DispatchQueue
    private let state = Mutex(State())
    private let runStep: StepRunner?
    private let isMainThread: @Sendable () -> Bool

    /// - Parameters:
    ///   - sink: Where the bytes go: ``SocketFrameSink`` for a socket, a recorder in tests.
    ///   - label: The drain queue's label.
    ///   - qos: The drain queue's class, chosen by the owner from what the connection carries.
    ///   - target: A serial queue the drain runs on (its target), nil for none.
    ///   - limit: The most bytes that may wait (not counting the step in flight).
    ///   - runStep: Runs each drain step, once per step (a hang scope); nil runs it bare.
    ///   - isMainThread: Whether the caller is on the main thread, which never writes inline; nil asks the system
    ///     (`pthread_main_np`). Tests inject it.
    public init(sink: any FrameSink, label: String, qos: DispatchQoS, target: DispatchQueue? = nil,
                limit: Int = FrameWriter.defaultLimit, runStep: StepRunner? = nil,
                isMainThread: (@Sendable () -> Bool)? = nil) {
        self.sink = sink
        self.limit = limit
        self.runStep = runStep
        self.isMainThread = isMainThread ?? { pthread_main_np() != 0 }
        queue = DispatchQueue(label: label, qos: qos, target: target)
    }

    /// Appends `bytes` after every message of the same priority written before, ahead of every lower priority.
    ///
    /// The writer owns `fds` from this call on, also when it refuses the message: it closes them once they are
    /// sent, dropped or refused. Never blocks: off the main thread an idle writer sends the message here with a
    /// send that never waits (the inline fast path), else the drain queue sends it.
    /// - Returns: nil, or why the message was refused (the socket failed, the writer closed, the backlog passed
    ///   the limit, or the descriptors are malformed).
    public func enqueue(_ bytes: Data, priority: MethodPriority, fds: [Int32] = []) -> Failure? {
        guard fds.count <= Self.maxFdsPerMessage else {
            Self.closeDescriptors(fds)
            return .tooManyFds(count: fds.count)
        }
        guard !bytes.isEmpty else {
            guard fds.isEmpty else {
                Self.closeDescriptors(fds)
                return .fdsWithoutBytes
            }
            return nil
        }
        let limit = limit
        let inline = !isMainThread() && sink.takesInline(byteCount: bytes.count, fdCount: fds.count)
        let outcome = state.withLock { state -> Outcome in
            if let failure = state.failure { return .refused(failure) }
            guard !state.closed else { return .refused(.closed) }
            if inline, state.mayWriteInline(priority) {
                switch sendInline(bytes, fds: fds) {
                case .success(let sent) where sent >= bytes.count:
                    return .sent
                case .success(let sent) where sent > 0:
                    // Half sent: its tail is the next thing on the wire; the descriptors went with its first byte.
                    state.rest = Message(bytes: Data(bytes.dropFirst(sent)), fds: [])
                    return .tail(startDrain: state.startDrain())
                case .success:
                    break
                case .failure(let failure):
                    state.failure = failure
                    return .failed(failure, dropped: state.removeAll())
                }
            }
            guard state.queuedBytes + bytes.count <= limit else { return .refused(.backlog(queued: state.queuedBytes)) }
            state.append(Message(bytes: bytes, fds: fds), priority: priority)
            return .queued(startDrain: state.startDrain())
        }
        switch outcome {
        case .sent:
            Self.closeDescriptors(fds)
            return nil
        case .tail(let startDrain):
            Self.closeDescriptors(fds)
            if startDrain { queue.async { [self] in drain() } }
            return nil
        case .queued(let startDrain):
            if startDrain { queue.async { [self] in drain() } }
            return nil
        case .refused(let failure):
            Self.closeDescriptors(fds)
            return failure
        case .failed(let failure, let dropped):
            Self.closeDescriptors(fds + dropped)
            return failure
        }
    }

    /// The inline send of a whole message (under the writer's lock, off the main thread).
    private func sendInline(_ bytes: Data, fds: [Int32]) -> Result<Int, Failure> {
        bytes.withUnsafeBytes { sink.trySend($0, fds: fds) }
    }

    /// The drain queue's QoS (tests).
    public var queueQoS: DispatchQoS { queue.qos }

    /// Bytes waiting for the socket, not counting the step in flight (diagnostics, tests).
    public var queuedBytes: Int { state.withLock { $0.queuedBytes } }

    /// Times a message woke the drain queue: each is a thread hop the inline fast path did not save (diagnostics,
    /// tests).
    public var queueHops: Int { state.withLock { $0.drainStarts } }

    /// Stops writing; queued messages are dropped and their descriptors closed. The owner shuts the socket down,
    /// which also ends a send in progress.
    public func close() {
        let dropped = state.withLock { state -> [Int32] in
            state.closed = true
            return state.removeAll()
        }
        Self.closeDescriptors(dropped)
    }

    // MARK: - Drain (serial queue)

    private func drain() {
        // wakeup-allow: bounded: each step sends queued messages and the loop stops when the queues are empty, the writer closed or a send failed
        while let batch = state.withLock({ $0.takeBatch(budget: Self.batchBytes) }) {
            let failure = sendStep(batch)
            Self.closeDescriptors(batch.fds)
            guard let failure else {
                state.withLock { $0.inFlight = false }
                continue
            }
            let dropped = state.withLock { state -> [Int32] in
                state.failure = failure
                state.draining = false
                state.inFlight = false
                return state.removeAll()
            }
            Self.closeDescriptors(dropped)
            return
        }
    }

    /// One drain step: the send of `batch`, inside ``runStep`` when the owner gave one.
    private func sendStep(_ batch: Batch) -> Failure? {
        guard let runStep else { return send(batch) }
        var failure: Failure?
        runStep { failure = send(batch) }
        return failure
    }

    private func send(_ batch: Batch) -> Failure? {
        let bytes = batch.messages.count == 1 ? batch.messages[0] : batch.joined()
        return bytes.withUnsafeBytes { raw -> Failure? in
            var offset = 0
            var fds = batch.fds
            // wakeup-allow: bounded: every pass sends at least one byte or returns
            while offset < raw.count {
                switch sink.send(UnsafeRawBufferPointer(rebasing: raw[offset...]), fds: fds) {
                case .success(let sent):
                    // A blocking send returns 0 only when it cannot progress; retrying would loop.
                    guard sent > 0 else { return .noProgress }
                    offset += sent
                    fds = []
                case .failure(let failure):
                    return failure
                }
            }
            return nil
        }
    }

    private static func closeDescriptors(_ fds: [Int32]) {
        for fd in fds { Darwin.close(fd) }
    }
}

extension FrameWriter {
    /// What ``FrameWriter/enqueue(_:priority:fds:)`` did with a message.
    private enum Outcome {
        /// Sent whole inline.
        case sent
        /// Sent in part inline; the tail waits as the state's `rest`.
        case tail(startDrain: Bool)
        /// Queued in its FIFO.
        case queued(startDrain: Bool)
        /// Refused before any byte left.
        case refused(Failure)
        /// The inline send failed; the writer dropped what waited (`dropped` descriptors).
        case failed(Failure, dropped: [Int32])
    }
}
