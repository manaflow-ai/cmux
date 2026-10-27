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

    /// - Parameters:
    ///   - sink: Where the bytes go: ``SocketFrameSink`` for a socket, a recorder in tests.
    ///   - label: The drain queue's label.
    ///   - qos: The drain queue's class, chosen by the owner from what the connection carries.
    ///   - target: A serial queue the drain runs on (its target), nil for none (p04-input-058).
    ///   - limit: The most bytes that may wait (not counting the step in flight).
    ///   - runStep: Runs each drain step, once per step (a hang scope); nil runs it bare.
    public init(sink: any FrameSink, label: String, qos: DispatchQoS, target: DispatchQueue? = nil,
                limit: Int = FrameWriter.defaultLimit, runStep: StepRunner? = nil) {
        self.sink = sink
        self.limit = limit
        self.runStep = runStep
        queue = DispatchQueue(label: label, qos: qos, target: target)
    }

    /// Appends `bytes` after every message of the same priority written before, ahead of every lower priority.
    ///
    /// The writer owns `fds` from this call on, also when it refuses the message: it closes them once they are
    /// sent, dropped or refused. Never blocks.
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
        let (failure, startDrain) = state.withLock { state -> (Failure?, Bool) in
            if let failure = state.failure { return (failure, false) }
            guard !state.closed else { return (.closed, false) }
            guard state.queuedBytes + bytes.count <= limit else { return (.backlog(queued: state.queuedBytes), false) }
            state.append(Message(bytes: bytes, fds: fds), priority: priority)
            guard !state.draining else { return (nil, false) }
            state.draining = true
            return (nil, true)
        }
        if failure != nil { Self.closeDescriptors(fds) }
        if startDrain { queue.async { [self] in drain() } }
        return failure
    }

    /// The drain queue's QoS (tests).
    public var queueQoS: DispatchQoS { queue.qos }

    /// Bytes waiting for the socket, not counting the step in flight (diagnostics, tests).
    public var queuedBytes: Int { state.withLock { $0.queuedBytes } }

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
            guard let failure else { continue }
            let dropped = state.withLock { state -> [Int32] in
                state.failure = failure
                state.draining = false
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

// MARK: - Queues

extension FrameWriter {
    private struct Message {
        let bytes: Data
        let fds: [Int32]
    }

    /// One drain step: messages in wire order; `fds` go with the first byte.
    private struct Batch {
        var messages: [Data]
        let fds: [Int32]
        var byteCount: Int

        func joined() -> Data {
            var data = Data(capacity: byteCount)
            for message in messages { data.append(message) }
            return data
        }
    }

    /// One priority's FIFO: popped slots are cleared at once, so a sent message's bytes are not retained.
    private struct Lane {
        private var slots: [Message?] = []
        private var head = 0

        var first: Message? { head < slots.count ? slots[head] : nil }

        mutating func append(_ message: Message) {
            slots.append(message)
        }

        mutating func popFirst() -> Message? {
            guard head < slots.count else { return nil }
            let message = slots[head]
            slots[head] = nil
            head += 1
            if head == slots.count {
                slots.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64, head * 2 >= slots.count {
                slots.removeFirst(head)
                head = 0
            }
            return message
        }

        /// Empties the FIFO; returns the descriptors of the dropped messages.
        mutating func removeAll() -> [Int32] {
            let fds = slots[head...].flatMap { $0?.fds ?? [] }
            slots.removeAll()
            head = 0
            return fds
        }
    }

    private struct State {
        /// Indexed by ``MethodPriority/rawValue``: input, control, bulk, background.
        private var lanes = [Lane](repeating: Lane(), count: MethodPriority.allCases.count)
        private(set) var queuedBytes = 0
        var draining = false
        var closed = false
        var failure: Failure?

        mutating func append(_ message: Message, priority: MethodPriority) {
            lanes[Int(priority.rawValue)].append(message)
            queuedBytes += message.bytes.count
        }

        /// The next drain step: the head of the highest non-empty FIFO. When that head is input or control, the
        /// following input and control heads join it in priority order while they fit in `budget`, stopping at a
        /// message with descriptors (its descriptors must ride its own first byte). A bulk or background head is
        /// sent alone: one chunk is the preemption boundary (p05-ipc.md section 3.2). nil, and draining ends,
        /// when there is nothing to send.
        mutating func takeBatch(budget: Int) -> Batch? {
            guard !closed, failure == nil, let first = popHighest() else {
                draining = false
                return nil
            }
            var batch = Batch(messages: [first.message.bytes], fds: first.message.fds,
                              byteCount: first.message.bytes.count)
            guard Self.joins(first.priority) else {
                queuedBytes -= batch.byteCount
                return batch
            }
            while let head = peekHighest(), Self.joins(head.priority), head.message.fds.isEmpty,
                  batch.byteCount + head.message.bytes.count <= budget {
                let next = head.message
                _ = popHighest()
                batch.messages.append(next.bytes)
                batch.byteCount += next.bytes.count
            }
            queuedBytes -= batch.byteCount
            return batch
        }

        mutating func removeAll() -> [Int32] {
            queuedBytes = 0
            var fds: [Int32] = []
            for index in lanes.indices { fds += lanes[index].removeAll() }
            return fds
        }

        /// Whether a message of `priority` may share a send with other waiting messages: only input and control,
        /// which are small; bulk and background are cut at BULK_FRAME_MAX and each chunk is its own step.
        private static func joins(_ priority: MethodPriority) -> Bool {
            switch priority {
            case .input, .control: true
            case .bulk, .background: false
            }
        }

        private func peekHighest() -> (message: Message, priority: MethodPriority)? {
            for priority in MethodPriority.allCases {
                if let message = lanes[Int(priority.rawValue)].first { return (message, priority) }
            }
            return nil
        }

        private mutating func popHighest() -> (message: Message, priority: MethodPriority)? {
            for priority in MethodPriority.allCases {
                if let message = lanes[Int(priority.rawValue)].popFirst() { return (message, priority) }
            }
            return nil
        }
    }
}
