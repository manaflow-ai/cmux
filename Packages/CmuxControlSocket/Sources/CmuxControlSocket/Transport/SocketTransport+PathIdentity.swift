internal import Foundation
internal import Darwin

extension SocketTransport {
    /// The filesystem identity of the socket inode at `path`, or nil when the
    /// path is missing or not a socket.
    ///
    /// - Parameter path: The socket path to stat.
    /// - Returns: The ``SocketPathIdentity``, or nil.
    public func pathIdentity(at path: String) -> SocketPathIdentity? {
        pathIdentityResult(at: path).identity
    }

    /// The identity plus the failing `errno` when no identity is available.
    func pathIdentityResult(
        at path: String
    ) -> (identity: SocketPathIdentity?, errnoCode: Int32?) {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            return (nil, errno)
        }
        guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFSOCK) else {
            return (nil, ENOTSOCK)
        }
        return (
            SocketPathIdentity(
                device: UInt64(st.st_dev),
                inode: UInt64(st.st_ino)
            ),
            nil
        )
    }

    /// Whether the socket inode at `path` is the one captured in `boundIdentity`.
    ///
    /// - Parameters:
    ///   - path: The socket path to stat.
    ///   - boundIdentity: The identity captured at bind time (nil never matches).
    /// - Returns: True only when the current inode equals `boundIdentity`.
    public func pathExists(_ path: String, matching boundIdentity: SocketPathIdentity?) -> Bool {
        guard let currentIdentity = pathIdentity(at: path),
              let boundIdentity else {
            return false
        }
        return currentIdentity == boundIdentity
    }

    /// Whether a live listener accepts connections at `path`.
    ///
    /// - Parameter path: The socket path to probe.
    public func pathAcceptsConnections(_ path: String) -> Bool {
        pathProbeResult(at: path) == .connected
    }

    /// Classifies the liveness of the socket path with a non-blocking
    /// `connect(2)` probe.
    ///
    /// - Parameter path: The socket path to probe.
    /// - Returns: The ``SocketPathProbeResult`` classification.
    public func pathProbeResult(at path: String) -> SocketPathProbeResult {
        let identityResult = pathIdentityResult(at: path)
        guard identityResult.identity != nil else {
            return identityResult.errnoCode == ENOENT ? .stale : .occupiedOrIndeterminate
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .occupiedOrIndeterminate }
        defer { close(fd) }

        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0 else { return .occupiedOrIndeterminate }
        guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            return .occupiedOrIndeterminate
        }
        defer { _ = fcntl(fd, F_SETFL, originalFlags) }

        guard var addr = unixSocketAddress(path: path) else { return .occupiedOrIndeterminate }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return .connected }

        let connectErrno = errno
        switch connectErrno {
        case ECONNREFUSED:
            return .refused
        case ENOENT:
            return .stale
        default:
            // Preserve anything not definitively stale. This keeps bind prep nonblocking
            // without ever unlinking a socket that might still have a live listener.
            return .occupiedOrIndeterminate
        }
    }
}
