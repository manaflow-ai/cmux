#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import Darwin

/// The descriptors and protocol-error flag of one ``ChromiumHostConnection``,
/// shared by the connection and its reader thread.
nonisolated final class ChromiumHostWireState: Sendable {
    private let wire: Mutex<ChromiumHostWire>
    private let protocolError = Atomic<Bool>(false)

    init(readFD: Int32, writeFD: Int32) {
        wire = Mutex(ChromiumHostWire(readFD: readFD, writeFD: writeFD))
    }

    var endedByProtocolError: Bool { protocolError.load(ordering: .acquiring) }

    /// One `write` of a whole frame; a short or refused write ends the wire.
    func send(_ bytes: [UInt8]) -> Bool {
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

    func close() {
        wire.withLock { wire in
            if wire.writeFD >= 0 {
                Darwin.close(wire.writeFD)
                wire.writeFD = -1
            }
            if wire.readFD >= 0 { Darwin.shutdown(wire.readFD, SHUT_RDWR) }
        }
    }

    /// The reader thread: blocking reads until EOF or a broken frame, frames
    /// into `continuation`; then closes its descriptor under the lock and
    /// finishes the stream.
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
#endif
