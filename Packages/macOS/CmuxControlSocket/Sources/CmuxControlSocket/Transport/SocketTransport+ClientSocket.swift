public import Foundation
internal import Darwin

extension SocketTransport {
    /// Creates the listener socket (`AF_UNIX`/`SOCK_STREAM`) with `FD_CLOEXEC`
    /// set so it is not inherited by PTY-child forks.
    ///
    /// - Returns: The descriptor and a nil errno on success, or `-1` and the
    ///   failing `errno`.
    public func makeListenerSocket() -> (fd: Int32, errnoCode: Int32?) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return (-1, errno)
        }
        if let errnoCode = configureCloseOnExec(fd) {
            close(fd)
            return (-1, errnoCode)
        }
        return (fd, nil)
    }

    /// Sets `O_NONBLOCK` on `fd`.
    ///
    /// - Parameter fd: The socket descriptor to configure.
    /// - Returns: Nil on success, the failing `errno` otherwise.
    public func configureNonBlocking(_ fd: Int32) -> Int32? {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            return errno
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return errno
        }
        return nil
    }

    /// Sets `FD_CLOEXEC` on `fd` so it is not inherited across `fork`/`exec`.
    ///
    /// Read-modify-write via `F_GETFD` to preserve any existing descriptor
    /// flags; a no-op when the flag is already set. macOS has no `accept4`/
    /// `SOCK_CLOEXEC`, so control-socket descriptors must be marked explicitly
    /// to keep them out of PTY-child forks (see the path-lock fd, which uses
    /// the same pattern).
    ///
    /// - Parameter fd: The descriptor to mark close-on-exec.
    /// - Returns: Nil on success, the failing `errno` otherwise.
    public func configureCloseOnExec(_ fd: Int32) -> Int32? {
        let flags = fcntl(fd, F_GETFD, 0)
        guard flags >= 0 else {
            return errno
        }
        if flags & FD_CLOEXEC != 0 {
            return nil
        }
        guard fcntl(fd, F_SETFD, flags | FD_CLOEXEC) >= 0 else {
            return errno
        }
        return nil
    }

    /// Clears `O_NONBLOCK` on `fd`; returns the failing `errno` otherwise.
    func configureBlocking(_ fd: Int32) -> Int32? {
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            return errno
        }
        guard fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) >= 0 else {
            return errno
        }
        return nil
    }

    func makeSocketTimeout(_ timeout: TimeInterval) -> timeval {
        let normalizedTimeout = max(timeout, 0)
        let seconds = floor(normalizedTimeout)
        let microseconds = (normalizedTimeout - seconds) * 1_000_000
        // Rounding can land exactly on 1_000_000, which is not a valid
        // tv_usec; clamp to the last representable microsecond instead.
        let clamped = min(Int32(microseconds.rounded()), 999_999)
        return timeval(tv_sec: Int(seconds), tv_usec: clamped)
    }

    /// Applies `timeout` as both `SO_RCVTIMEO` and `SO_SNDTIMEO` (best effort).
    ///
    /// - Parameters:
    ///   - fd: The socket descriptor to configure.
    ///   - timeout: The receive and send timeout to apply.
    public func configureSocketTimeouts(_ fd: Int32, timeout: TimeInterval) {
        var socketTimeout = makeSocketTimeout(timeout)
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
    }

    func configureSocketSendTimeout(_ fd: Int32, timeout: TimeInterval) -> Int32? {
        var socketTimeout = makeSocketTimeout(timeout)
        let result = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        return result == 0 ? nil : errno
    }

    /// Sets `SO_NOSIGPIPE` on `fd` (macOS).
    ///
    /// - Parameter fd: The socket descriptor to configure.
    /// - Returns: Nil on success, the failing `errno` otherwise.
    public func configureNoSigPipe(_ fd: Int32) -> Int32? {
#if os(macOS)
        var noSigPipe: Int32 = 1
        let result = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        return result == 0 ? nil : errno
#else
        _ = fd
        return nil
#endif
    }

    /// Configures a freshly accepted client socket: blocking mode, the
    /// transport's read/write timeouts, and `SO_NOSIGPIPE`.
    ///
    /// - Parameter fd: The freshly accepted client socket descriptor.
    /// - Returns: Nil on success, or the failing ``SocketStageFailure``.
    public func configureAcceptedClientSocket(_ fd: Int32) -> SocketStageFailure? {
        // Set close-on-exec first, before any later configuration step can
        // fail and before a concurrent PTY fork can inherit the descriptor
        // (macOS has no `accept4`/`SOCK_CLOEXEC`).
        if let errnoCode = configureCloseOnExec(fd) {
            return SocketStageFailure(stage: "accept_client_configure_cloexec", errnoCode: errnoCode)
        }
        if let errnoCode = configureBlocking(fd) {
            return SocketStageFailure(stage: "accept_client_configure_blocking", errnoCode: errnoCode)
        }
        var readTimeout = makeSocketTimeout(clientReadTimeout)
        let readTimeoutResult = withUnsafePointer(to: &readTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        if readTimeoutResult != 0 {
            return SocketStageFailure(stage: "accept_client_configure_receive_timeout", errnoCode: errno)
        }
        if let errnoCode = configureSocketSendTimeout(fd, timeout: clientWriteTimeout) {
            return SocketStageFailure(stage: "accept_client_configure_send_timeout", errnoCode: errnoCode)
        }
        if let errnoCode = configureNoSigPipe(fd) {
            return SocketStageFailure(stage: "accept_client_configure_no_sigpipe", errnoCode: errnoCode)
        }
        return nil
    }

    /// Whether an accepted-client configuration failure is worth reporting.
    ///
    /// Timeout/NOSIGPIPE failures caused by the client disconnecting between
    /// accept and configure are expected churn and are suppressed.
    ///
    /// - Parameters:
    ///   - stage: The failing stage from ``configureAcceptedClientSocket(_:)``.
    ///   - errnoCode: The failing `errno`.
    public func shouldReportAcceptedClientConfigFailure(stage: String, errnoCode: Int32) -> Bool {
        guard stage == "accept_client_configure_receive_timeout" ||
            stage == "accept_client_configure_send_timeout" ||
            stage == "accept_client_configure_no_sigpipe" else {
            return true
        }
        return errnoCode != EINVAL &&
            errnoCode != ENOTCONN &&
            errnoCode != ECONNRESET &&
            errnoCode != EPIPE &&
            errnoCode != EBADF
    }
}
