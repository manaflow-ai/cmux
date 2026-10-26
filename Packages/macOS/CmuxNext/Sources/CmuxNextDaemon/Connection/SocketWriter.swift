import Darwin
import Foundation
import CmuxNextCompat

/// Writes to a connected socket without ever blocking the caller
/// (architecture.md 5a). Callers are actors on the cooperative pool; a
/// blocking `write` there parked a pool thread for as long as the daemon did
/// not read its socket (a Unix socket buffers only a few KB, so a burst of
/// commands to a busy daemon filled it).
///
/// `write` appends to a bounded outbox and returns at once; one private
/// serial queue drains the outbox in call order. Only that queue's thread
/// ever waits on the socket. Past `limit` queued bytes `write` fails with a
/// description instead of buffering without bound. (`MSG_DONTWAIT` is not
/// honored for Unix stream sockets on macOS, and making the descriptor
/// nonblocking would break the transport's blocking reader thread.)
final class SocketWriter: Sendable {
    private struct State {
        var pending = Data()
        var draining = false
        var closed = false
        var failure: SocketWriteFailure?
    }

    private let fd: Int32
    private let limit: Int
    private let queue: DispatchQueue
    private let state = Mutex(State())

    /// - Parameter qos: The drain queue's class, chosen by the owner from what the connection
    ///   carries (``DaemonWireStats/Role/writerQoS``).
    init(fd: Int32, label: String, qos: DispatchQoS, limit: Int = 64 << 20) {
        self.fd = fd
        self.limit = limit
        self.queue = DispatchQueue(label: label, qos: qos)
        // A write to a closed peer must fail with EPIPE, not raise SIGPIPE
        // (whose default action ends the process), whatever the caller set.
        // The option fails (EINVAL) once the peer is gone, so writes also
        // pass MSG_NOSIGNAL.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Appends `bytes` after everything written before. Returns an error
    /// description when the socket failed, closed, or the backlog passed the limit.
    func write(_ bytes: Data) -> SocketWriteFailure? {
        let (error, startDrain) = state.withLock { state -> (SocketWriteFailure?, Bool) in
            if let failure = state.failure { return (failure, false) }
            guard !state.closed else { return (.closed, false) }
            guard state.pending.count + bytes.count <= limit else {
                return (.backlog(queued: state.pending.count), false)
            }
            state.pending.append(bytes)
            guard !state.draining else { return (nil, false) }
            state.draining = true
            return (nil, true)
        }
        if startDrain { queue.async { [self] in drain() } }
        return error
    }

    /// The drain queue's QoS (tests).
    var queueQoS: DispatchQoS { queue.qos }

    /// Bytes waiting for the socket (diagnostics, tests).
    var queuedBytes: Int { state.withLock { $0.pending.count } }

    /// Stops writing; queued bytes are dropped. The owner shuts the
    /// descriptor down, which also ends a write in progress.
    func close() {
        state.withLock { state in
            state.closed = true
            state.pending = Data()
        }
    }

    // MARK: - Private (serial queue)

    private func drain() {
        // wakeup-allow: bounded: drains queued bytes and stops when the queue is empty, closed, or a write fails or makes no progress
        while true {
            let chunk = state.withLock { state -> Data? in
                guard !state.closed, !state.pending.isEmpty else {
                    state.draining = false
                    return nil
                }
                defer { state.pending = Data() }
                return state.pending
            }
            guard let chunk else { return }
            if let failure = Self.writeAll(chunk, fd: fd) {
                state.withLock { state in
                    state.failure = failure
                    state.pending = Data()
                    state.draining = false
                }
                return
            }
        }
    }

    private static func writeAll(_ bytes: Data, fd: Int32) -> SocketWriteFailure? {
        bytes.withUnsafeBytes { raw -> SocketWriteFailure? in
            guard var pointer = raw.baseAddress else { return nil }
            var remaining = raw.count
            while remaining > 0 {
                // concurrency-allow: runs only on this writer's private serial queue, never the main thread or the cooperative pool.
                let written = Darwin.send(fd, pointer, remaining, MSG_NOSIGNAL)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    return code == EPIPE || code == ECONNRESET ? .peerClosed : .errno(code)
                }
                // A blocking write returns 0 only when it cannot progress;
                // retrying would loop without writing anything.
                if written == 0 { return .noProgress }
                remaining -= written
                pointer += written
            }
            return nil
        }
    }
}

/// Why `SocketWriter.write` failed.
enum SocketWriteFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The other end closed the connection (EPIPE, ECONNRESET).
    case peerClosed
    /// The owner closed the writer.
    case closed
    /// The peer stopped reading and the backlog passed the limit.
    case backlog(queued: Int)
    /// A blocking write returned 0 (no progress).
    case noProgress
    case errno(Int32)

    var description: String {
        switch self {
        case .peerClosed: "peer closed the socket"
        case .closed: "socket closed"
        case .backlog(let queued): "cmux-tui is not reading its socket (\(queued) bytes queued)"
        case .noProgress: "write: no progress"
        case .errno(let code): "write: \(String(cString: strerror(code)))"
        }
    }
}

extension DaemonWireStats.Role {
    /// The class of this connection's ``SocketWriter`` queue and of its reader thread, by what it carries
    /// (threading-model.md, QoS table). Both directions serve the same waiter, so they share one class. Only the
    /// terminal attach connection, which carries typed keys (`TerminalAttachment.enqueueInput`) and their echo, runs at
    /// user-interactive: control commands, replies and events (automation, sidebar churn) and bulk loopback forwards never
    /// share a keystroke's class. Chromium maps its default thread type to user-initiated and keeps user-interactive for
    /// the threads input and display wait on (base/threading/platform_thread_apple.mm).
    var writerQoS: DispatchQoS {
        switch self {
        case .terminalAttach:
            // qos-allow: key echo path: typed keys reach the daemon on this connection and the echo frame waits for its bytes
            .userInteractive
        case .control, .pageRelay, .agentSessionAttach, .journalRead, .sessionEnding, .shutdown:
            // userBlocking: a person waits now for the result of a click, an open or quit.
            .userInitiated
        case .loopbackForward:
            // Bulk forwarded page bytes: one class below the roles a person waits for, so a large stream never
            // crowds them out (not the userVisible lane mapping, which is user-initiated; threading-model.md).
            .default
        case .socketProbe:
            // bestEffort: a liveness probe nobody watches.
            .utility
        }
    }

    /// The class of this connection's reader thread (`cmux-tui reader <path>`): the writer's, as a thread QoS.
    var readerQoS: QualityOfService {
        switch writerQoS.qosClass {
        case .userInteractive: .userInteractive
        case .userInitiated: .userInitiated
        case .utility: .utility
        case .background: .background
        default: .default
        }
    }
}
