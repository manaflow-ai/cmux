import CmuxNextCompat
import Darwin
import Foundation

/// cmux's end of the wire to one Chromium host (a stream socket, one end of
/// a `socketpair`): frames from the host arrive as ``frames``, read on a
/// thread of the connection's own; frames to the host leave with one
/// non-blocking `send` (`MSG_DONTWAIT`).
///
/// The read side owns a `dup` of the socket and closes it when the stream
/// ends; the write side owns the original behind a `Mutex` and closes it in
/// ``close()``. Neither side ever touches the other's descriptor, so a
/// closed number that the system reuses is never read or written.
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
    /// The write side's descriptor, -1 once closed. Held only across one
    /// non-blocking `send` (the lock carve-out: a short critical section
    /// called synchronously from the main actor, where an actor would add a hop per input event).
    private let writer: Mutex<Int32>
    private let link = ChromiumHostLinkState()

    /// Takes ownership of `fd`; ``close()`` closes it.
    init(fd: Int32) {
        var size = Self.sendBuffer
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        writer = Mutex(fd)
        let (stream, continuation) = AsyncStream<ChromiumHostFrame>.makeStream(bufferingPolicy: .bufferingOldest(Self.frameBacklog))
        frames = stream
        let readFD = dup(fd)
        guard readFD >= 0 else {
            continuation.finish()
            return
        }
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        let link = link
        let thread = Thread { readFrames(fd: readFD, into: continuation, link: link) }
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
        let sent = writer.withLock { fd -> Bool in
            guard fd >= 0 else { return false }
            let written = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
            return written == bytes.count
        }
        if sent { return true }
        // A short or refused write leaves the stream mid-frame: it cannot
        // carry another frame, so the connection ends here.
        close(protocolError: true)
        return false
    }

    /// Ends the connection: the stream finishes (the read side sees EOF) and
    /// the write descriptor closes.
    func close() {
        close(protocolError: false)
    }

    /// The connection ended because the host broke the wire (a bad frame, a
    /// flood of frames, a full send buffer), not because the host closed it.
    var endedByProtocolError: Bool { link.protocolError.load(ordering: .acquiring) }

    private func close(protocolError: Bool) {
        if protocolError { link.protocolError.store(true, ordering: .releasing) }
        writer.withLock { fd in
            guard fd >= 0 else { return }
            // Both directions of the socket, so the read side's dup sees EOF.
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// What the read thread tells the write side.
nonisolated final class ChromiumHostLinkState: Sendable {
    let protocolError = Atomic<Bool>(false)
}

/// The read thread: blocking reads of `fd` (its own dup) until EOF or a broken
/// frame, frames into `continuation`; closes `fd` and finishes the stream.
private nonisolated func readFrames(fd: Int32, into continuation: AsyncStream<ChromiumHostFrame>.Continuation,
                                    link: ChromiumHostLinkState) {
    var buffer: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    var open = true
    while open {
        let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }  // EOF (the host ended, or close() shut the socket) or an error
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
            link.protocolError.store(true, ordering: .releasing)
            // The socket, not only this dup: the write side's next send fails.
            Darwin.shutdown(fd, SHUT_RDWR)
            open = false
        } else {
            buffer.removeFirst(start)
        }
    }
    Darwin.close(fd)
    continuation.finish()
}
