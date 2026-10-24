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
/// the system may have reused. The descriptors live in a
/// ``ChromiumHostWireState`` that the reader thread holds instead of the
/// connection, so a connection dropped without ``close()`` still deinits:
/// its `deinit` closes the wire, the host reads EOF and the reader ends.
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
    private let state: ChromiumHostWireState

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
        let state = ChromiumHostWireState(readFD: readFD, writeFD: writeFD)
        self.state = state
        let (stream, continuation) = AsyncStream<ChromiumHostFrame>.makeStream(bufferingPolicy: .bufferingOldest(Self.frameBacklog))
        frames = stream
        // The thread holds the state, never the connection: see the type's doc.
        let thread = Thread { state.readFrames(fd: readFD, into: continuation) }
        thread.name = "com.cmuxterm.chromium-host.read"
        thread.start()
    }

    deinit {
        close()
    }

    /// A frame's payload is over ``ChromiumHostFrame/maxPayload``: the host
    /// would refuse it and end, so it is never written. The caller checks
    /// first (``ChromiumHostSession/open(_:)`` refuses such a URL).
    static func fits(_ frame: ChromiumHostFrame) -> Bool {
        frame.payload.count <= ChromiumHostFrame.maxPayload
    }

    /// Writes one frame; false when the host is gone or has stopped reading
    /// (then the connection is closed and nothing more is sent), or when the
    /// frame does not ``fits(_:)`` (nothing is written and the connection stays).
    @discardableResult
    func send(_ frame: ChromiumHostFrame) -> Bool { // perf-hot: 5us cef-host-input (every forwarded input event)
        guard Self.fits(frame) else { return false }
        return state.send(frame.encoded())
    }

    /// Ends the connection: the write descriptor closes (the host reads EOF)
    /// and the reader is woken with EOF and closes its own descriptor.
    func close() {
        state.close()
    }

    /// The connection ended because the host broke the wire (a bad frame, a
    /// flood of frames, a full send buffer), not because the host closed it.
    var endedByProtocolError: Bool { state.endedByProtocolError }
}
