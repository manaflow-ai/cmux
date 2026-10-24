import CmuxNextCompat
import Darwin
import Foundation

/// cmux's end of the wire to one Chromium host: two stream socket pairs, one
/// per direction. Frames to the host leave on ``ChromiumHostWire/send`` with one
/// `write` on a non-blocking descriptor; frames from the host are read by a
/// thread of the connection's own, blocked in `read` on a second descriptor,
/// and arrive as ``frames``.
///
/// Two pairs, because a socket's file status flags are shared by every
/// descriptor of it, and macOS ignores `MSG_DONTWAIT` on Unix sockets (checked
/// 2026-10-23): one socket cannot be written non-blocking from the main actor
/// and read blocking from a thread.
///
/// Both descriptors are owned by one `Mutex` (the lock carve-out: a short
/// critical section around one non-blocking `write`, called synchronously on
/// every input event, where an actor would add a hop). The reader closes its
/// descriptor under the lock after EOF; ``close()`` shuts it down under the
/// same lock only while it is open, so no side ever touches a closed number
/// the system may have reused.
///
/// Bounded both ways. The kernel send buffer is ``sendBuffer``: a host that
/// stops reading fills it, ``send(_:)`` then reports `false` and the
/// connection ends (its owner ends the host). The stream holds at most
/// ``frameBacklog`` unread frames: a host that floods it is ended the same way.
nonisolated final class ChromiumHostConnection: Sendable {
    /// Bytes the kernel may hold for the host: about 4,000 input frames.
    static let sendBuffer: Int32 = 256 * 1024
    /// Frames from the host the main actor has not read yet; more ends the connection.
    static let frameBacklog = 4_096

    let frames: AsyncStream<ChromiumHostFrame>
    private let wire: Mutex<ChromiumHostWire>
    private let protocolError = Atomic<Bool>(false)

    /// Takes ownership of both descriptors: `readFD` carries frames from the
    /// host, `writeFD` frames to it. ``close()`` (or the host's EOF) closes them.
    init(readFD: Int32, writeFD: Int32) {
        _ = fcntl(writeFD, F_SETFL, fcntl(writeFD, F_GETFL) | O_NONBLOCK)
        var size = Self.sendBuffer
        _ = setsockopt(writeFD, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        for fd in [readFD, writeFD] {
            var noSigPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        wire = Mutex(ChromiumHostWire(readFD: readFD, writeFD: writeFD))
        let (stream, continuation) = AsyncStream<ChromiumHostFrame>.makeStream(bufferingPolicy: .bufferingOldest(Self.frameBacklog))
        frames = stream
        let thread = Thread { [self] in readFrames(fd: readFD, into: continuation) }
        thread.name = "com.cmuxterm.chromium-host.read"
        thread.start()
    }

    deinit {
        close()
    }

    /// Writes one frame; false when the host is gone or has stopped reading
    /// (then the connection is closed and nothing more is sent).
    @discardableResult
    func send(_ frame: ChromiumHostFrame) -> Bool { // perf-hot: 5us cef-host-input (every forwarded input event)
        let bytes = frame.encoded()
        let sent = wire.withLock { wire -> Bool in
            guard wire.writeFD >= 0 else { return false }
            let written = bytes.withUnsafeBytes { Darwin.write(wire.writeFD, $0.baseAddress, $0.count) }
            return written == bytes.count
        }
        if sent { return true }
        // A short or refused write leaves the stream mid-frame: it cannot
        // carry another frame, so the connection ends here.
        protocolError.store(true, ordering: .releasing)
        close()
        return false
    }

    /// Ends the connection: the write descriptor closes (the host reads EOF)
    /// and the reader is woken with EOF and closes its own descriptor.
    func close() {
        wire.withLock { wire in
            if wire.writeFD >= 0 {
                Darwin.close(wire.writeFD)
                wire.writeFD = -1
            }
            if wire.readFD >= 0 { Darwin.shutdown(wire.readFD, SHUT_RDWR) }
        }
    }

    /// The connection ended because the host broke the wire (a bad frame, a
    /// flood of frames, a full send buffer), not because the host closed it.
    var endedByProtocolError: Bool { protocolError.load(ordering: .acquiring) }

    /// The reader thread: blocking reads until EOF or a broken frame, frames
    /// into `continuation`; then closes its descriptor under the lock and
    /// finishes the stream.
    private func readFrames(fd: Int32, into continuation: AsyncStream<ChromiumHostFrame>.Continuation) {
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
        wire.withLock { wire in
            Darwin.close(wire.readFD)
            wire.readFD = -1
        }
        if protocolError.load(ordering: .acquiring) { close() }
        continuation.finish()
    }
}

/// The two descriptors of a connection, -1 once closed.
nonisolated struct ChromiumHostWire: Sendable {
    var readFD: Int32
    var writeFD: Int32
}
