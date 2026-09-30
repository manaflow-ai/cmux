import Darwin
import Foundation

/// A connected Unix domain stream socket.
///
/// Reads and writes use separate descriptors (`dup(2)` of the connected socket) so each
/// side owns its own lifetime: the read descriptor belongs to a `DispatchSource` read
/// source and closes in its cancel handler, as Dispatch requires; the write descriptor
/// belongs to this actor, which serializes writes with ``close()``. A write can therefore
/// never reach a descriptor number that was closed and reused.
public actor UnixSocketConnection {
    /// Bytes read from the socket. Finishes on EOF, error, or ``close()``.
    public nonisolated let chunks: AsyncStream<Data>
    private let writeFD: Int32
    private var isClosed = false
    // Dispatch has no async-native socket read. The source only forwards bytes into the
    // stream. `DispatchSourceRead.cancel()` is thread-safe and the reference never changes.
    private nonisolated(unsafe) let source: any DispatchSourceRead

    /// Connects to the socket at `path`.
    /// - Throws: ``UnixSocketError`` when the socket cannot be created or connected.
    public init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.socket(errno) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw UnixSocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.connect(code)
        }
        let writeFD = dup(fd)
        guard writeFD >= 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.socket(code)
        }
        self.writeFD = writeFD

        let (chunks, yield) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.chunks = chunks
        let readFD = fd
        let source = DispatchSource.makeReadSource(
            fileDescriptor: readFD,
            queue: DispatchQueue(label: "com.cmuxterm.acpmux.socket-read")
        )
        source.setEventHandler { [source] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
            if count > 0 {
                yield.yield(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler {
            yield.finish()
            Darwin.close(readFD)
        }
        self.source = source
        source.resume()
    }

    /// Writes all bytes, retrying partial writes.
    /// - Throws: ``UnixSocketError/closed`` after ``close()``, ``UnixSocketError/write(_:)`` when the peer is gone.
    public func write(_ data: Data) throws {
        guard !isClosed else { throw UnixSocketError.closed }
        let fd = writeFD
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.write(errno)
                }
                offset += written
            }
        }
    }

    /// Shuts the socket down, finishes ``chunks``, and releases both descriptors.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        // Shutdown wakes the read source with EOF; its cancel handler closes the read side.
        shutdown(writeFD, SHUT_RDWR)
        source.cancel()
        Darwin.close(writeFD)
    }

    deinit {
        if !isClosed {
            source.cancel()
            Darwin.close(writeFD)
        }
    }
}

/// Errors raised by ``UnixSocketConnection``.
public enum UnixSocketError: Error, Sendable, Equatable {
    /// `socket(2)` or `dup(2)` failed with the given errno.
    case socket(Int32)
    /// The path does not fit in `sockaddr_un`.
    case pathTooLong(String)
    /// `connect(2)` failed with the given errno.
    case connect(Int32)
    /// `write(2)` failed with the given errno.
    case write(Int32)
    /// The connection was closed locally.
    case closed
}
