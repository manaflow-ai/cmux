public import Darwin

/// Probes whether a Unix domain socket path has a live listener running as the
/// expected user, without writing anything to it.
///
/// Socket discovery uses this to choose among candidate control sockets, some
/// of which sit at predictable paths in the shared `/tmp` directory. A
/// listener owned by another user fails the probe, so discovery moves on to
/// the next candidate:
///
/// ```swift
/// if UnixSocketConnectProbe().acceptsConnections(atPath: candidate) {
///     return candidate
/// }
/// ```
public struct UnixSocketConnectProbe: Sendable, Equatable {
    /// The check the connected listener must pass.
    public let peerCheck: UnixSocketPeerCheck
    /// How long to wait for a connect in progress, in milliseconds.
    public let timeoutMilliseconds: Int32

    /// Creates a probe.
    ///
    /// - Parameters:
    ///   - peerCheck: The check the connected listener must pass. Defaults to
    ///     a check for this process's effective user ID.
    ///   - timeoutMilliseconds: How long to wait for a connect in progress.
    public init(
        peerCheck: UnixSocketPeerCheck = UnixSocketPeerCheck(),
        timeoutMilliseconds: Int32 = 150
    ) {
        self.peerCheck = peerCheck
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    /// Whether a listener accepts a connection at `path` and passes
    /// ``peerCheck``.
    ///
    /// - Parameter path: The socket path to probe.
    /// - Returns: `true` when a connection completes within the timeout and
    ///   the listener runs as the expected user.
    public func acceptsConnections(atPath path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0 else { return false }
        guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else { return false }
        defer { _ = fcntl(fd, F_SETFL, originalFlags) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            return false
        }
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            return peerCheck.isTrustedPeer(fd)
        }
        let connectErrno = errno
        guard connectErrno == EINPROGRESS || connectErrno == EAGAIN || connectErrno == EWOULDBLOCK else {
            return false
        }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollFD, 1, timeoutMilliseconds) > 0 else {
            return false
        }
        guard (pollFD.revents & Int16(POLLOUT)) != 0 else {
            return false
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = withUnsafeMutablePointer(to: &socketError) { errorPointer in
            withUnsafeMutablePointer(to: &socketErrorLength) { lengthPointer in
                getsockopt(fd, SOL_SOCKET, SO_ERROR, errorPointer, lengthPointer)
            }
        }
        return optionResult == 0 && socketError == 0 && peerCheck.isTrustedPeer(fd)
    }
}
