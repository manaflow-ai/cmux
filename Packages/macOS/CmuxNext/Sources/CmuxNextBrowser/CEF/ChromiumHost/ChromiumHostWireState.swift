#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import Darwin
import Dispatch

/// The descriptors, the input outbox and the protocol-error flag of one
/// ``ChromiumHostConnection``, shared by the connection, its reader thread
/// and its writable source.
nonisolated final class ChromiumHostWireState: Sendable {
    private let wire: Mutex<ChromiumHostWire>
    private let protocolError = Atomic<Bool>(false)
    /// Runs the writable source: it flushes the outbox when a full socket takes more.
    private let writeQueue = DispatchQueue(label: "com.cmuxterm.chromium-host.write", qos: .userInitiated)

    init(readFD: Int32, writeFD: Int32) {
        wire = Mutex(ChromiumHostWire(readFD: readFD, writeFD: writeFD))
    }

    var endedByProtocolError: Bool { protocolError.load(ordering: .acquiring) }

    /// What waits in the outbox (tests, `debug.chromium_host`).
    var backlog: ChromiumHostWireBacklog {
        wire.withLock { wire in
            ChromiumHostWireBacklog(waiting: wire.outbox.waitingCount, coalescible: wire.outbox.coalescibleCount,
                                    coalesced: wire.outbox.coalesced, writableArmed: wire.writableArmed)
        }
    }

    /// Writes `frame` at once, or queues it behind frames the full socket has
    /// not taken (``ChromiumHostInputOutbox``). `holdsLaterWheels`: `frame`
    /// starts a wheel sequence, and later wheels wait for ``wheelAcknowledged()``.
    /// False when the wire is closed, or broken now: the outbox is full or the
    /// socket failed (then the connection ends).
    func send(_ frame: ChromiumHostFrame, holdsLaterWheels: Bool) -> Bool {
        let sent = wire.withLock { wire -> Bool? in
            guard wire.writeFD >= 0 else { return nil }
            guard wire.outbox.push(frame) else { return false }
            if holdsLaterWheels { wire.outbox.holdWheelsUntilAck() }
            // Armed: the socket is full and the writable source flushes, in order.
            return wire.writableArmed || flushLocked(&wire)
        }
        guard let sent else { return false }
        if !sent { fail() }
        return sent
    }

    /// The host took the first wheel of a sequence: the held wheel goes, and wheels go at once again.
    func wheelAcknowledged() {
        let flushed = wire.withLock { wire -> Bool in
            guard wire.writeFD >= 0 else { return true }
            guard wire.outbox.wheelAcknowledged() else { return false }
            return wire.writableArmed || flushLocked(&wire)
        }
        if !flushed { fail() }
    }

    /// Writes what the outbox holds while the socket takes it; arms the
    /// writable source when the socket is full and disarms it once drained.
    /// False when the socket failed.
    private func flushLocked(_ wire: inout ChromiumHostWire) -> Bool {
        let fd = wire.writeFD
        switch wire.outbox.flush({ Self.write(fd, $0) }) {
        case .drained:
            if wire.writableArmed {
                wire.writable?.suspend()
                wire.writableArmed = false
            }
            return true
        case .blocked:
            if !wire.writableArmed {
                let source = wire.writable ?? makeWritableSource(fd: fd)
                wire.writable = source
                wire.writableArmed = true
                source.resume()
            }
            return true
        case .failed:
            return false
        }
    }

    /// Created suspended on the first full socket; it owns the descriptor
    /// from then on and closes it when cancelled.
    private func makeWritableSource(fd: Int32) -> any DispatchSourceWrite {
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: writeQueue)
        source.setEventHandler { [weak self] in self?.writable() }
        source.setCancelHandler { Darwin.close(fd) }
        return source
    }

    /// The writable source fired: the socket takes more.
    private func writable() {
        let flushed = wire.withLock { wire -> Bool in
            guard wire.writeFD >= 0, wire.writableArmed else { return true }
            return flushLocked(&wire)
        }
        if !flushed { fail() }
    }

    private static func write(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> ChromiumHostInputOutbox.WriteOutcome {
        let written = Darwin.write(fd, bytes.baseAddress, bytes.count)
        if written >= 0 { return .wrote(written) }
        switch errno {
        case EINTR: return .interrupted
        case EAGAIN, EWOULDBLOCK, ENOBUFS: return .wouldBlock
        default: return .failed
        }
    }

    /// The outbox overflowed or the socket failed: the stream cannot carry
    /// another frame, so the connection ends here.
    private func fail() {
        protocolError.store(true, ordering: .releasing)
        close()
    }

    func close() {
        wire.withLock { wire in
            if wire.writeFD >= 0 {
                if let source = wire.writable {
                    // Its cancel handler closes the descriptor; a suspended source must be resumed to run it.
                    source.cancel()
                    if !wire.writableArmed { source.resume() }
                    wire.writable = nil
                    wire.writableArmed = false
                } else {
                    Darwin.close(wire.writeFD)
                }
                wire.writeFD = -1
                wire.outbox = ChromiumHostInputOutbox()
            }
            if wire.readFD >= 0 { Darwin.shutdown(wire.readFD, SHUT_RDWR) }
        }
    }

    /// Returns once the reader thread has closed its descriptor: at once when
    /// it has, else when ``readFrames(fd:into:)`` closes it.
    func readerEnded() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ended = wire.withLock { wire -> Bool in
                guard wire.readFD >= 0 else { return true }
                wire.readerEndWaiters.append(continuation)
                return false
            }
            if ended { continuation.resume() }
        }
    }

    /// The reader thread: blocking reads until EOF or a broken frame, frames
    /// into `continuation`; then closes its descriptor under the lock, wakes
    /// ``readerEnded()`` and finishes the stream.
    func readFrames(fd: Int32, into continuation: AsyncStream<ChromiumHostFrame>.Continuation) {
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var open = true
        while open {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }  // EOF: the host ended, or close() shut the socket down
            buffer.append(contentsOf: chunk[0..<count])
            var start = 0
            // Each frame consumes at least a header, so this ends within the bytes read.
            var decoded = ChromiumHostFrame.decode(buffer[start...])
            while case .frame(let frame, let consumed) = decoded {
                if case .dropped = continuation.yield(frame) {
                    decoded = .invalid  // over the backlog: the host floods the wire
                    break
                }
                start += consumed
                decoded = ChromiumHostFrame.decode(buffer[start...])
            }
            if decoded == .invalid {
                protocolError.store(true, ordering: .releasing)
                open = false
            } else {
                buffer.removeFirst(start)
            }
        }
        let waiters = wire.withLock { wire -> [CheckedContinuation<Void, Never>] in
            Darwin.close(wire.readFD)
            wire.readFD = -1
            let waiters = wire.readerEndWaiters
            wire.readerEndWaiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
        if protocolError.load(ordering: .acquiring) { close() }
        continuation.finish()
    }
}

/// The two descriptors of a connection, -1 once closed, the frames the
/// socket has not taken, and the callers of
/// ``ChromiumHostWireState/readerEnded()`` waiting for the reader to close its own.
nonisolated struct ChromiumHostWire {
    var readFD: Int32
    var writeFD: Int32
    var readerEndWaiters: [CheckedContinuation<Void, Never>] = []
    var outbox = ChromiumHostInputOutbox()
    /// Flushes ``outbox`` when the full socket takes more; made on the first full socket.
    var writable: (any DispatchSourceWrite)?
    /// ``writable`` is resumed: the socket was full and frames wait.
    var writableArmed = false
}

/// What waits in a connection's outbox.
nonisolated struct ChromiumHostWireBacklog: Equatable, Sendable {
    /// Frames the socket has not taken (the partly written one not counted).
    var waiting: Int
    /// Of them, pointer moves, wheels and geometry, the held wheel counted.
    var coalescible: Int
    /// Frames folded into a waiting one since the connection opened.
    var coalesced: UInt64
    /// The socket was full and the writable source waits to flush.
    var writableArmed: Bool
}
#endif
