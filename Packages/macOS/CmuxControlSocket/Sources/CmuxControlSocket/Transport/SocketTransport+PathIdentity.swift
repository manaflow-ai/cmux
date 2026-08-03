internal import Foundation
internal import Darwin

/// Maximum main-actor occupancy while a rare retained-listener proof waits
/// for one local nonblocking connection to finish.
nonisolated private let retainedPathConnectPollTimeoutMs: Int32 = 100

/// Result of proving that a pathname still routes to a retained bound listener.
enum SocketBoundPathVerificationResult: Equatable, Sendable {
    case verified(SocketPathIdentity)
    case failed(SocketStageFailure)
}

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

    /// Captures the identity immediately after bind, including deterministic
    /// stage failures used by lifecycle tests.
    func boundPathIdentityResult(
        at path: String
    ) -> (identity: SocketPathIdentity?, errnoCode: Int32?) {
        if let errnoCode = injectedErrnoCode(stage: "stat_bound_path", path: path) {
            return (nil, errnoCode)
        }
        return pathIdentityResult(at: path)
    }

    /// Proves that `path` still routes to `listenerSocket` before adopting its inode.
    ///
    /// A later `lstat(2)` alone is insufficient after the immediate post-bind
    /// lookup failed: another process may have unlinked and rebound the same
    /// pathname. The retained descriptor is made nonblocking and listening,
    /// preexisting queued connections are drained, and a private loopback
    /// connection must arrive on that exact descriptor. A final identity read
    /// closes the remaining replacement race before ownership is promoted.
    func verifyRetainedBoundPath(
        at path: String,
        listenerSocket: Int32
    ) -> SocketBoundPathVerificationResult {
        let identityResult = boundPathIdentityResult(at: path)
        guard let candidateIdentity = identityResult.identity else {
            return .failed(SocketStageFailure(
                stage: "stat_bound_path",
                errnoCode: identityResult.errnoCode ?? EIO
            ))
        }

        if let errnoCode = configureNonBlocking(listenerSocket) {
            return .failed(SocketStageFailure(
                stage: "configure_nonblocking",
                errnoCode: errnoCode
            ))
        }
        guard listen(listenerSocket, listenBacklog) == 0 else {
            return .failed(SocketStageFailure(stage: "listen", errnoCode: errno))
        }

        while true {
            let queuedSocket = accept(listenerSocket, nil, nil)
            if queuedSocket >= 0 {
                _ = configureCloseOnExec(queuedSocket)
                close(queuedSocket)
                continue
            }
            let acceptErrno = errno
            if acceptErrno == EINTR {
                continue
            }
            guard acceptErrno == EAGAIN || acceptErrno == EWOULDBLOCK else {
                return .failed(SocketStageFailure(
                    stage: "verify_bound_path",
                    errnoCode: acceptErrno
                ))
            }
            break
        }

        let (verificationClient, createErrno) = makeListenerSocket()
        guard verificationClient >= 0 else {
            return .failed(SocketStageFailure(
                stage: "verify_bound_path",
                errnoCode: createErrno ?? EIO
            ))
        }
        defer { close(verificationClient) }
        if let errnoCode = configureNonBlocking(verificationClient) {
            return .failed(SocketStageFailure(
                stage: "verify_bound_path",
                errnoCode: errnoCode
            ))
        }
        guard var address = unixSocketAddress(path: path) else {
            return .failed(SocketStageFailure(
                stage: "verify_bound_path",
                errnoCode: ENAMETOOLONG
            ))
        }
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(
                    verificationClient,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        let systemConnectErrno = connectResult == 0 ? nil : errno
        // Run the real syscall first, then allow tests to make a completed
        // local connection present as POSIX's permitted in-progress result.
        let injectedConnectErrno = injectedErrnoCode(
            stage: "verify_bound_path_connect",
            path: path
        )
        if let connectErrno = nonblockingConnectCompletionErrno(
            socket: verificationClient,
            initialResult: injectedConnectErrno == nil ? connectResult : -1,
            initialErrno: injectedConnectErrno ?? systemConnectErrno ?? EIO
        ) {
            return .failed(SocketStageFailure(
                stage: "verify_bound_path",
                errnoCode: connectErrno
            ))
        }

        var acceptedSocket: Int32 = -1
        repeat {
            acceptedSocket = accept(listenerSocket, nil, nil)
        } while acceptedSocket < 0 && errno == EINTR
        guard acceptedSocket >= 0 else {
            return .failed(SocketStageFailure(stage: "verify_bound_path", errnoCode: ESTALE))
        }
        _ = configureCloseOnExec(acceptedSocket)
        close(acceptedSocket)

        guard pathIdentity(at: path) == candidateIdentity else {
            return .failed(SocketStageFailure(stage: "verify_bound_path", errnoCode: ESTALE))
        }
        return .verified(candidateIdentity)
    }

    /// Completes one nonblocking connect with a single bounded readiness wait.
    ///
    /// - Returns: `nil` when connected, otherwise the final socket error.
    private func nonblockingConnectCompletionErrno(
        socket: Int32,
        initialResult: Int32,
        initialErrno: Int32
    ) -> Int32? {
        guard initialResult != 0 else { return nil }
        guard initialErrno == EINPROGRESS || initialErrno == EALREADY else {
            return initialErrno
        }

        var descriptor = pollfd(
            fd: socket,
            events: Int16(POLLOUT),
            revents: 0
        )
        let pollResult = poll(&descriptor, 1, retainedPathConnectPollTimeoutMs)
        guard pollResult > 0 else {
            return pollResult == 0 ? ETIMEDOUT : errno
        }
        let completionEvents = Int16(POLLOUT | POLLERR | POLLHUP)
        guard descriptor.revents & Int16(POLLNVAL) == 0 else { return EBADF }
        guard descriptor.revents & completionEvents != 0 else { return EIO }

        var socketError: Int32 = 0
        var socketErrorSize = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            socket,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorSize
        ) == 0 else {
            return errno
        }
        return socketError == 0 ? nil : socketError
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
        _ = configureCloseOnExec(fd)

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
