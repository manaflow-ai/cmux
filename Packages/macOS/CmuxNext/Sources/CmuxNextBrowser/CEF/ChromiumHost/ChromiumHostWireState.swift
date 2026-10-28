#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Dispatch
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// The descriptors, the input outbox and the protocol-error flag of one
/// ``ChromiumHostConnection``, shared by the connection, its reader thread
/// and its writable source.
nonisolated final class ChromiumHostWireState: Sendable {
    /// A full socket that takes no byte for a whole window ends the
    /// connection: the host's UI thread is stuck. Chrome's hang monitor calls
    /// a renderer unresponsive after `kHungRendererDelay` with no input ACK
    /// (`content/browser/renderer_host/render_widget_host_impl.cc`); ending
    /// the host loses its page state, so cmux waits twice as long. The check
    /// runs once per window, so a stuck host ends in 30 to 60 s, the control
    /// channel's 60 s ceiling.
    static let stallLimit: Duration = .seconds(30)

    private let wire: Mutex<ChromiumHostWire>
    private let protocolError = Atomic<Bool>(false)
    /// Runs the writable source: it flushes the outbox when a full socket takes more.
    private let writeQueue = DispatchQueue(label: "com.cmuxterm.chromium-host.write", qos: .userInitiated)
    /// The stall check: pending from the first full socket until a check finds the outbox drained.
    private let stall: DemandTimer

    init(readFD: Int32, writeFD: Int32, clock: any Clock<Duration>) {
        wire = Mutex(ChromiumHostWire(readFD: readFD, writeFD: writeFD))
        stall = DemandTimer(owner: "chromium-host.input-stall", clock: clock)
    }

    var endedByProtocolError: Bool { protocolError.load(ordering: .acquiring) }

    /// What waits in the outbox (tests, `debug.chromium_host`).
    var backlog: ChromiumHostWireBacklog {
        wire.withLock { wire in
            ChromiumHostWireBacklog(waiting: wire.outbox.waitingCount, coalescible: wire.outbox.coalescibleCount,
                                    waitingBytes: wire.outbox.waitingBytes, coalesced: wire.outbox.coalesced,
                                    writableArmed: wire.writableArmed)
        }
    }

    /// Writes `frame` at once, or queues it behind frames the full socket has
    /// not taken (``ChromiumHostInputOutbox``). False when the wire is closed,
    /// or broken now: the outbox is full or the socket failed (then the
    /// connection ends).
    func send(_ frame: ChromiumHostFrame) -> Bool {
        let next = wire.withLock { wire -> AfterFlush? in
            guard wire.writeFD >= 0 else { return nil }
            guard wire.outbox.push(frame) else { return .fail }
            // Armed: the socket is full and the writable source flushes, in order.
            if wire.writableArmed { return AfterFlush.done }
            return flushLocked(&wire)
        }
        guard let next else { return false }
        return finish(next)
    }

    /// What a locked step leaves to do once the lock is released.
    private enum AfterFlush {
        case done
        /// Start a stall window; the socket had taken this many bytes.
        case watch(UInt64)
        case fail
    }

    /// One `write` of what the outbox holds; arms the writable source when
    /// the socket is full and disarms it once drained.
    private func flushLocked(_ wire: inout ChromiumHostWire) -> AfterFlush {
        let fd = wire.writeFD
        // SAFETY: the outbox's view is valid for the call, and write only reads it during the call.
        switch wire.outbox.flush({ unsafe Self.write(fd, $0) }) {
        case .drained:
            if wire.writableArmed {
                wire.writable?.suspend()
                wire.writableArmed = false
            }
            return .done
        case .blocked:
            if !wire.writableArmed {
                let source = wire.writable ?? makeWritableSource(fd: fd)
                wire.writable = source
                wire.writableArmed = true
                source.resume()
            }
            guard !wire.stallWatched else { return .done }
            wire.stallWatched = true
            return .watch(wire.outbox.taken)
        case .failed:
            return .fail
        }
    }

    /// Acts on a locked step's result with the lock released (the timer has its own lock).
    private func finish(_ next: AfterFlush) -> Bool {
        switch next {
        case .done:
            return true
        case .watch(let taken):
            stall.schedule(after: Self.stallLimit) { [weak self] in self?.stallCheck(since: taken) }
            return true
        case .fail:
            fail()
            return false
        }
    }

    /// A stall window passed. Bytes still waiting and none taken since
    /// `taken` end the connection; some taken start the next window; a
    /// drained outbox ends the check until the socket fills again. Only this
    /// check and the first full socket schedule the timer, so it is never
    /// reset while a window runs.
    private func stallCheck(since taken: UInt64) {
        let next = wire.withLock { wire -> AfterFlush in
            guard wire.writeFD >= 0, wire.writableArmed else {
                wire.stallWatched = false
                return .done
            }
            return wire.outbox.taken == taken ? .fail : .watch(wire.outbox.taken)
        }
        _ = finish(next)
    }

    /// Created suspended on the first full socket; it owns the descriptor
    /// from then on and closes it when cancelled.
    private func makeWritableSource(fd: Int32) -> any DispatchSourceWrite {
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: writeQueue)
        source.setEventHandler { [weak self] in self?.writable() }
        source.setCancelHandler { Darwin.close(fd) }
        return source
    }

    /// The writable source fired: the socket takes more. One `write` per
    /// fire; the source fires again while the socket has room.
    private func writable() {
        let next = wire.withLock { wire -> AfterFlush in
            guard wire.writeFD >= 0, wire.writableArmed else { return .done }
            return flushLocked(&wire)
        }
        _ = finish(next)
    }

    private static func write(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> ChromiumHostInputOutbox.WriteOutcome {
        // SAFETY: write reads at most bytes.count bytes of the caller's view during the call.
        let written = unsafe Darwin.write(fd, bytes.baseAddress, bytes.count)
        if written >= 0 { return .wrote(written) }
        switch errno {
        case EINTR: return .interrupted
        case EAGAIN, EWOULDBLOCK, ENOBUFS: return .wouldBlock
        default: return .failed
        }
    }

    /// The outbox overflowed, or the socket failed or stalled: the stream
    /// cannot carry another frame, so the connection ends here.
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
        // Closed for good: nothing schedules the check again.
        stall.cancel()
    }

    /// Returns once the reader thread has closed its descriptor: at once when
    /// it has, else when ``readFrames(fd:into:)`` closes it.
    func readerEnded() async {
        try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            let ended = wire.withLock { wire -> Bool in
                guard wire.readFD >= 0 else { return true }
                wire.readerEndWaiters.append(continuation)
                return false
            }
            if ended { continuation.resume(returning: ()) }
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
            let room = chunk.count
            // SAFETY: read writes at most `room` bytes, the array's size, into its buffer during the call.
            let count = unsafe blockingRead(fd, &chunk, room)
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
            // A frame never claims more than the bytes read; one that does is an invalid wire too.
            if decoded != .invalid, start <= buffer.count {
                buffer.removeFirst(start)
            } else {
                protocolError.store(true, ordering: .releasing)
                open = false
            }
        }
        let waiters = wire.withLock { wire -> [OnceContinuation<Void, OnceContinuationError>] in
            Darwin.close(wire.readFD)
            wire.readFD = -1
            let waiters = wire.readerEndWaiters
            wire.readerEndWaiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume(returning: ()) }
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
    var readerEndWaiters: [OnceContinuation<Void, OnceContinuationError>] = []
    var outbox = ChromiumHostInputOutbox()
    /// Flushes ``outbox`` when the full socket takes more; made on the first full socket.
    var writable: (any DispatchSourceWrite)?
    /// ``writable`` is resumed: the socket was full and frames wait.
    var writableArmed = false
    /// A stall check is pending (``ChromiumHostWireState/stallLimit``).
    var stallWatched = false
}

/// What waits in a connection's outbox.
nonisolated struct ChromiumHostWireBacklog: Equatable, Sendable {
    /// Frames the socket has not taken (the partly written one not counted).
    var waiting: Int
    /// Of them, pointer moves, wheels and geometry.
    var coalescible: Int
    /// Bytes the socket has not taken, the partly written frame's rest counted.
    var waitingBytes: Int
    /// Frames folded into a waiting one since the connection opened.
    var coalesced: UInt64
    /// The socket was full and the writable source waits to flush.
    var writableArmed: Bool
}
#endif
