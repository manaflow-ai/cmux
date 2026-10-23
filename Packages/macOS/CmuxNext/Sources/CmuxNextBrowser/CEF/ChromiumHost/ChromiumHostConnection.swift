import CmuxNextCompat
import Darwin
import Dispatch

/// cmux's end of the wire to one Chromium host (a stream socket, one end of
/// a `socketpair`): frames from the host arrive as ``frames``, read off the
/// main thread; frames to the host leave with a non-blocking `write`.
///
/// The send buffer is bounded (``sendBuffer``). A host that stops reading
/// fills it; then ``send(_:)`` reports `false` once, the connection stops
/// sending, and its owner ends the host (a hung browser process gets no more
/// input). A write is never retried and never blocks the caller.
nonisolated final class ChromiumHostConnection: Sendable {
    /// Bytes the kernel may hold for the host: about 4,000 input frames.
    static let sendBuffer: Int32 = 256 * 1024
    /// Frames from the host the main actor has not read yet; more ends the connection.
    static let frameBacklog = 4_096

    let fd: Int32
    let frames: AsyncStream<ChromiumHostFrame>
    private let reader: ChromiumHostReader

    /// Takes ownership of `fd` (made non-blocking here); ``close()`` closes it.
    init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var size = Self.sendBuffer
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        // Bounded: a host sends a few frames per page event. One that floods the
        // stream faster than the main actor reads it is broken, and the reader
        // ends the connection (ChromiumHostReader.readAvailable).
        let (stream, continuation) = AsyncStream<ChromiumHostFrame>.makeStream(bufferingPolicy: .bufferingOldest(Self.frameBacklog))
        frames = stream
        reader = ChromiumHostReader(fd: fd, continuation: continuation)
        reader.start()
    }

    /// Writes one frame; false when the host is gone or has stopped reading
    /// (then nothing more is sent).
    @discardableResult
    func send(_ frame: ChromiumHostFrame) -> Bool { // perf-hot: 5us cef-host-input (every forwarded input event)
        guard !reader.isClosed else { return false }
        let bytes = frame.encoded()
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if written == bytes.count { return true }
        // A short or refused write leaves the stream mid-frame: it cannot carry
        // another frame, so the connection ends here.
        reader.close(protocolError: true)
        return false
    }

    /// Ends the connection: the stream finishes and the fd closes.
    func close() {
        reader.close()
    }

    /// The connection ended because the host broke the wire (a bad frame, a
    /// flood of frames, a full send buffer), not because the host closed it.
    var endedByProtocolError: Bool { reader.protocolError }
}

/// The read side: a read source on a private serial queue decodes frames
/// into the connection's stream.
private nonisolated final class ChromiumHostReader: @unchecked Sendable { // crash-allow: wraps a DispatchSourceRead (no async socket read in Foundation); `buffer` and `source` change only on the serial `queue`, and `isClosed` reads an atomic flag
    private let fd: Int32
    private let queue = DispatchQueue(label: "com.cmuxterm.chromium-host.read")
    private let continuation: AsyncStream<ChromiumHostFrame>.Continuation
    private var source: (any DispatchSourceRead)?
    private var buffer: [UInt8] = []
    private let closedFlag = ChromiumHostClosedFlag()
    private let protocolErrorFlag = ChromiumHostClosedFlag()

    init(fd: Int32, continuation: AsyncStream<ChromiumHostFrame>.Continuation) {
        self.fd = fd
        self.continuation = continuation
    }

    var isClosed: Bool { closedFlag.isSet }
    var protocolError: Bool { protocolErrorFlag.isSet }

    func start() {
        queue.async { [self] in
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in readAvailable() }
            source.setCancelHandler { [self] in
                Darwin.close(fd)
                continuation.finish()
            }
            self.source = source
            source.resume()
        }
    }

    func close(protocolError: Bool = false) {
        // Before the closed flag: whoever sees the stream end reads the cause.
        if protocolError { _ = protocolErrorFlag.set() }
        guard closedFlag.set() else { return }
        queue.async { [self] in
            source?.cancel()
            source = nil
        }
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else {
            close()  // EOF: the host closed the wire or ended
            return
        }
        buffer.append(contentsOf: chunk[0..<count])
        var start = 0
        // Each frame consumes at least a header, so this ends within the bytes read.
        var decoded = ChromiumHostFrame.decode(buffer[start...])
        while case .frame(let frame, let consumed) = decoded {
            if case .dropped = continuation.yield(frame) {
                close(protocolError: true)  // over the backlog: the host floods the wire
                return
            }
            start += consumed
            decoded = ChromiumHostFrame.decode(buffer[start...])
        }
        if decoded == .invalid {
            close(protocolError: true)
            return
        }
        buffer.removeFirst(start)
    }
}


/// Set once, read from any thread.
// One-shot flag read synchronously by `send` on the main thread and set from
// the read queue: an atomic, not an actor (a lock-free compare-and-set).
private nonisolated final class ChromiumHostClosedFlag: Sendable {
    private let value = Atomic<Bool>(false)
    var isSet: Bool { value.load(ordering: .acquiring) }
    /// True for the call that set it.
    func set() -> Bool { value.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged }
}
