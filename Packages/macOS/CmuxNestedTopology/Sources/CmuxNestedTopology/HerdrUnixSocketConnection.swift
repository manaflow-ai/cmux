#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Blocking POSIX Unix-domain socket connection used by ``HerdrNestedTopologyClient``.
///
/// Cancellation closes the file descriptor promptly so blocked reads/writes unblock.
final class HerdrUnixSocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    /// Whether the underlying descriptor is still open.
    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    /// Connects to `path` with a wall-clock deadline.
    init(path: String, timeout: Duration) throws {
        if path.isEmpty || path.utf8.count >= 104 {
            throw NestedTopologyProviderError.transport("invalid unix socket path length")
        }

        #if canImport(Darwin)
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let socketFD = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard socketFD >= 0 else {
            throw NestedTopologyProviderError.transport("socket() failed errno=\(errno)")
        }

        // Non-blocking connect + poll so connectTimeout is enforceable.
        let flags = fcntl(socketFD, F_GETFL, 0)
        guard flags >= 0, fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let saved = errno
            DarwinClose(socketFD)
            throw NestedTopologyProviderError.transport("fcntl() failed errno=\(saved)")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        let sunPathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        withUnsafeMutableBytes(of: &address) { raw in
            pathBytes.withUnsafeBytes { src in
                raw.baseAddress!.advanced(by: sunPathOffset)
                    .copyMemory(from: src.baseAddress!, byteCount: pathBytes.count)
            }
        }

        // Darwin sockaddr_un leads with sun_len; sizeof(sun_family) alone is one byte short.
        let addrLen = socklen_t(sunPathOffset + pathBytes.count)
        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketFD, $0, addrLen)
            }
        }

        if connectResult != 0 {
            let connectErrno = errno
            if connectErrno != EINPROGRESS {
                DarwinClose(socketFD)
                if connectErrno == ETIMEDOUT {
                    throw NestedTopologyProviderError.connectTimeout
                }
                throw NestedTopologyProviderError.transport("connect() failed errno=\(connectErrno)")
            }

            var pollFD = pollfd(fd: socketFD, events: Int16(POLLOUT), revents: 0)
            let timeoutMs = max(1, Int32(timeout.millisecondsRoundedUp))
            let pollResult = poll(&pollFD, 1, timeoutMs)
            if pollResult == 0 {
                DarwinClose(socketFD)
                throw NestedTopologyProviderError.connectTimeout
            }
            if pollResult < 0 {
                let saved = errno
                DarwinClose(socketFD)
                throw NestedTopologyProviderError.transport("poll() failed errno=\(saved)")
            }

            var soError: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            let gotError = withUnsafeMutablePointer(to: &soError) { errorPtr in
                getsockopt(socketFD, SOL_SOCKET, SO_ERROR, errorPtr, &soLen)
            }
            if gotError != 0 || soError != 0 {
                let code = gotError != 0 ? errno : soError
                DarwinClose(socketFD)
                if code == ETIMEDOUT {
                    throw NestedTopologyProviderError.connectTimeout
                }
                throw NestedTopologyProviderError.transport("connect completion failed errno=\(code)")
            }
        }

        // Restore blocking mode; request deadlines are enforced around reads.
        _ = fcntl(socketFD, F_SETFL, flags)
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #endif
        self.fd = socketFD
    }

    deinit {
        close()
    }

    /// Closes the descriptor. Safe to call multiple times and from cancellation handlers.
    func close() {
        lock.lock()
        let current = fd
        fd = -1
        lock.unlock()
        if current >= 0 {
            DarwinClose(current)
        }
    }

    /// Writes all bytes or throws.
    func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            var written = 0
            let total = rawBuffer.count
            let base = rawBuffer.baseAddress!
            while written < total {
                let currentFD = lockedFD()
                guard currentFD >= 0 else { throw NestedTopologyProviderError.cancelled }
                #if canImport(Darwin)
                let result = send(currentFD, base.advanced(by: written), total - written, 0)
                #else
                let result = send(currentFD, base.advanced(by: written), total - written, Int32(MSG_NOSIGNAL))
                #endif
                if result < 0 {
                    let saved = errno
                    if saved == EINTR { continue }
                    if saved == EPIPE || saved == ECONNRESET {
                        throw NestedTopologyProviderError.unexpectedEOF
                    }
                    throw NestedTopologyProviderError.transport("send() failed errno=\(saved)")
                }
                if result == 0 {
                    throw NestedTopologyProviderError.unexpectedEOF
                }
                written += result
            }
        }
    }

    /// Reads up to `maxLength` bytes, waiting up to `timeout`.
    func readSome(maxLength: Int, timeout: Duration) throws -> Data {
        precondition(maxLength > 0)
        let currentFD = lockedFD()
        guard currentFD >= 0 else { throw NestedTopologyProviderError.cancelled }

        var pollFD = pollfd(fd: currentFD, events: Int16(POLLIN | POLLHUP), revents: 0)
        let timeoutMs = max(1, Int32(timeout.millisecondsRoundedUp))
        let pollResult = poll(&pollFD, 1, timeoutMs)
        if pollResult == 0 {
            throw NestedTopologyProviderError.requestTimeout
        }
        if pollResult < 0 {
            let saved = errno
            if saved == EINTR {
                return Data()
            }
            if lockedFD() < 0 {
                throw NestedTopologyProviderError.cancelled
            }
            throw NestedTopologyProviderError.transport("poll() failed errno=\(saved)")
        }

        var buffer = [UInt8](repeating: 0, count: maxLength)
        let result = recv(currentFD, &buffer, maxLength, 0)
        if result < 0 {
            let saved = errno
            if saved == EINTR {
                return Data()
            }
            if lockedFD() < 0 {
                throw NestedTopologyProviderError.cancelled
            }
            throw NestedTopologyProviderError.transport("recv() failed errno=\(saved)")
        }
        if result == 0 {
            throw NestedTopologyProviderError.unexpectedEOF
        }
        return Data(buffer.prefix(result))
    }

    private func lockedFD() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fd
    }
}

private func DarwinClose(_ fd: Int32) {
    _ = close(fd)
}

extension Duration {
    fileprivate var millisecondsRoundedUp: Int64 {
        let components = self.components
        let fromSeconds = components.seconds * 1_000
        let fromAttoseconds = (components.attoseconds + 1_000_000_000_000_000 - 1) / 1_000_000_000_000_000
        return fromSeconds + fromAttoseconds
    }
}
