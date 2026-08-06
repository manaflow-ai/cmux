internal import Foundation
internal import Darwin

extension SocketTransport {
    /// Maximum number of preexisting clients discarded during one retained-path proof.
    private static let maximumQueuedConnectionsToDrain = 64
    /// Maximum interrupted accepts tolerated before startup returns to its retry policy.
    private static let maximumInterruptedDrainAcceptAttempts = 64

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
    /// connection must return a random challenge on that exact descriptor. A
    /// final identity read closes the remaining replacement race before
    /// ownership is promoted.
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

        var drainedConnectionCount = 0
        var interruptedAcceptCount = 0
        while drainedConnectionCount < Self.maximumQueuedConnectionsToDrain {
            let queuedSocket: Int32
            let acceptErrno: Int32
            if let injectedErrno = injectedErrnoCode(
                stage: "verify_bound_path_drain_accept",
                path: path
            ) {
                queuedSocket = -1
                acceptErrno = injectedErrno
            } else {
                queuedSocket = accept(listenerSocket, nil, nil)
                acceptErrno = queuedSocket >= 0 ? 0 : errno
            }
            if queuedSocket >= 0 {
                _ = configureCloseOnExec(queuedSocket)
                close(queuedSocket)
                drainedConnectionCount += 1
                continue
            }
            if acceptErrno == EINTR {
                interruptedAcceptCount += 1
                if interruptedAcceptCount >= Self.maximumInterruptedDrainAcceptAttempts {
                    return .pending(SocketStageFailure(
                        stage: "verify_bound_path_drain",
                        errnoCode: EINTR
                    ))
                }
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
        if drainedConnectionCount == Self.maximumQueuedConnectionsToDrain {
            return .pending(SocketStageFailure(
                stage: "verify_bound_path_drain",
                errnoCode: EAGAIN
            ))
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
        let effectiveConnectResult = injectedConnectErrno == nil ? connectResult : -1
        let effectiveConnectErrno = injectedConnectErrno ?? systemConnectErrno ?? EIO
        guard effectiveConnectResult == 0 || isPendingSocketConnectErrno(effectiveConnectErrno) else {
            return .failed(SocketStageFailure(
                stage: "verify_bound_path",
                errnoCode: effectiveConnectErrno
            ))
        }
        if effectiveConnectResult != 0 {
            switch nonBlockingConnectCompletion(
                socket: verificationClient,
                path: path
            ) {
            case .connected:
                break
            case .pending(let errnoCode):
                return .pending(SocketStageFailure(
                    stage: "verify_bound_path_pending",
                    errnoCode: errnoCode
                ))
            case .failed(let errnoCode):
                return .failed(SocketStageFailure(
                    stage: "verify_bound_path",
                    errnoCode: errnoCode
                ))
            }
        }

        var generator = SystemRandomNumberGenerator()
        let verificationChallenge = Data((0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        })
        if let errnoCode = configureNoSigPipe(verificationClient) {
            return .failed(SocketStageFailure(
                stage: "verify_bound_path",
                errnoCode: errnoCode
            ))
        }
        if let errnoCode = writeVerificationChallenge(
            verificationChallenge,
            to: verificationClient
        ) {
            if errnoCode == EAGAIN || errnoCode == EWOULDBLOCK {
                return .pending(SocketStageFailure(
                    stage: "verify_bound_path_pending",
                    errnoCode: errnoCode
                ))
            }
            return .failed(SocketStageFailure(
                stage: "verify_bound_path",
                errnoCode: errnoCode
            ))
        }

        var inspectedConnectionCount = 0
        interruptedAcceptCount = 0
        var didReceiveChallenge = false
        while inspectedConnectionCount < Self.maximumQueuedConnectionsToDrain {
            let acceptedSocket = accept(listenerSocket, nil, nil)
            if acceptedSocket < 0 {
                let acceptErrno = errno
                if acceptErrno == EINTR {
                    interruptedAcceptCount += 1
                    if interruptedAcceptCount >= Self.maximumInterruptedDrainAcceptAttempts {
                        return .pending(SocketStageFailure(
                            stage: "verify_bound_path_drain",
                            errnoCode: EINTR
                        ))
                    }
                    continue
                }
                if acceptErrno == EAGAIN || acceptErrno == EWOULDBLOCK {
                    // The challenge client reached another listener. A queued
                    // connection on this descriptor cannot prove ownership.
                    return .failed(SocketStageFailure(
                        stage: "verify_bound_path",
                        errnoCode: ESTALE
                    ))
                }
                return .failed(SocketStageFailure(
                    stage: "verify_bound_path",
                    errnoCode: acceptErrno
                ))
            }

            inspectedConnectionCount += 1
            _ = configureCloseOnExec(acceptedSocket)
            let nonBlockingErrno = configureNonBlocking(acceptedSocket)
            let carriesChallenge = nonBlockingErrno == nil
                && acceptedSocketCarriesVerificationChallenge(
                    verificationChallenge,
                    socket: acceptedSocket
                )
            close(acceptedSocket)
            if let nonBlockingErrno {
                return .failed(SocketStageFailure(
                    stage: "verify_bound_path",
                    errnoCode: nonBlockingErrno
                ))
            }
            if carriesChallenge {
                didReceiveChallenge = true
                break
            }
        }
        guard didReceiveChallenge else {
            return .pending(SocketStageFailure(
                stage: "verify_bound_path_drain",
                errnoCode: EAGAIN
            ))
        }

        guard pathIdentity(at: path) == candidateIdentity else {
            return .failed(SocketStageFailure(stage: "verify_bound_path", errnoCode: ESTALE))
        }
        return .verified(candidateIdentity)
    }

    private func writeVerificationChallenge(_ challenge: Data, to socket: Int32) -> Int32? {
        challenge.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    socket,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR {
                    continue
                }
                return written == 0 ? EIO : errno
            }
            return nil
        }
    }

    private func acceptedSocketCarriesVerificationChallenge(
        _ challenge: Data,
        socket: Int32
    ) -> Bool {
        var received = [UInt8](repeating: 0, count: challenge.count)
        var offset = 0
        var interruptedReadCount = 0
        while offset < received.count {
            let count = received.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    socket,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR {
                interruptedReadCount += 1
                guard interruptedReadCount < Self.maximumInterruptedDrainAcceptAttempts else {
                    return false
                }
                continue
            }
            return false
        }
        return Data(received) == challenge
    }

    /// Checks a nonblocking connection without waiting on the calling actor.
    /// A zero-timeout `poll` only snapshots readiness; an incomplete connect is
    /// returned to the listener's bounded asynchronous startup retry path.
    private func nonBlockingConnectCompletion(
        socket: Int32,
        path: String
    ) -> SocketConnectCompletion {
        if let injectedErrno = injectedErrnoCode(
            stage: "verify_bound_path_readiness",
            path: path
        ) {
            return isPendingSocketConnectErrno(injectedErrno)
                ? .pending(injectedErrno)
                : .failed(injectedErrno)
        }

        var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        var readinessResult: Int32
        repeat {
            readinessResult = poll(&descriptor, 1, 0)
        } while readinessResult < 0 && errno == EINTR

        if readinessResult == 0 {
            return .pending(EINPROGRESS)
        }
        guard readinessResult > 0 else {
            return .failed(errno)
        }
        guard descriptor.revents & Int16(POLLNVAL) == 0 else {
            return .failed(EBADF)
        }

        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            socket,
            SOL_SOCKET,
            SO_ERROR,
            &socketError,
            &socketErrorLength
        ) == 0 else {
            return .failed(errno)
        }
        if socketError == 0 {
            return .connected
        }
        return isPendingSocketConnectErrno(socketError)
            ? .pending(socketError)
            : .failed(socketError)
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

func isPendingSocketConnectErrno(_ errnoCode: Int32) -> Bool {
    errnoCode == EINPROGRESS
        || errnoCode == EALREADY
        || errnoCode == EAGAIN
        || errnoCode == EWOULDBLOCK
}
