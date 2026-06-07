public import Foundation
internal import Darwin

extension SocketTransport {
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
