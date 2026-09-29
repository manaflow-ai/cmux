import Darwin
import Foundation

/// A connected Unix domain stream socket that surfaces inbound bytes as an `AsyncStream`.
///
/// Reads use a `DispatchSource` read source because Darwin has no async-native socket
/// read; the source only forwards bytes into the stream and holds no other state.
/// Writes are blocking `write(2)` calls made from the owning actor.
public final class UnixSocketConnection: Sendable {
    /// Bytes read from the socket. Finishes on EOF, error, or ``close()``.
    public let chunks: AsyncStream<Data>
    private let fd: Int32
    // DispatchSourceRead is thread-safe for cancel(); the source is created once in init
    // and never reassigned, so sharing the reference across isolation domains is safe.
    nonisolated(unsafe) private let source: any DispatchSourceRead

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
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
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
        self.fd = fd

        var continuation: AsyncStream<Data>.Continuation!
        chunks = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        let yield = continuation!
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd,
            queue: DispatchQueue(label: "com.cmuxterm.acpmux.socket-read")
        )
        source.setEventHandler { [source] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                yield.yield(Data(buffer[0..<count]))
            } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler {
            yield.finish()
            Darwin.close(fd)
        }
        self.source = source
        yield.onTermination = { [source] _ in source.cancel() }
        source.resume()
    }

    /// Writes all bytes, retrying partial writes.
    /// - Throws: ``UnixSocketError/write(_:)`` when the peer is gone.
    public func write(_ data: Data) throws {
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

    /// Closes the socket and finishes ``chunks``.
    public func close() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}

/// Errors raised by ``UnixSocketConnection``.
public enum UnixSocketError: Error, Sendable, Equatable {
    /// `socket(2)` failed with the given errno.
    case socket(Int32)
    /// The path does not fit in `sockaddr_un`.
    case pathTooLong(String)
    /// `connect(2)` failed with the given errno.
    case connect(Int32)
    /// `write(2)` failed with the given errno.
    case write(Int32)
}
