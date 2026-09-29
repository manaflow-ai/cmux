import Darwin
import Foundation
import Synchronization

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
        var failure: String?
    }

    private let fd: Int32
    private let limit: Int
    private let queue: DispatchQueue
    private let state = Mutex(State())

    init(fd: Int32, label: String, limit: Int = 64 << 20) {
        self.fd = fd
        self.limit = limit
        self.queue = DispatchQueue(label: label)
    }

    /// Appends `bytes` after everything written before. Returns an error
    /// description when the socket failed, closed, or the backlog passed the limit.
    func write(_ bytes: Data) -> String? {
        let (error, startDrain) = state.withLock { state -> (String?, Bool) in
            if let failure = state.failure { return (failure, false) }
            guard !state.closed else { return ("socket closed", false) }
            guard state.pending.count + bytes.count <= limit else {
                return ("cmux-tui is not reading its socket (\(state.pending.count) bytes queued)", false)
            }
            state.pending.append(bytes)
            guard !state.draining else { return (nil, false) }
            state.draining = true
            return (nil, true)
        }
        if startDrain { queue.async { [self] in drain() } }
        return error
    }

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

    private static func writeAll(_ bytes: Data, fd: Int32) -> String? {
        bytes.withUnsafeBytes { raw -> String? in
            guard var pointer = raw.baseAddress else { return nil }
            var remaining = raw.count
            while remaining > 0 {
                // concurrency-allow: runs only on this writer's private serial queue, never the main thread or the cooperative pool.
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return "write: \(String(cString: strerror(errno)))"
                }
                remaining -= written
                pointer += written
            }
            return nil
        }
    }
}
