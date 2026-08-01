public import Foundation
internal import Darwin

extension SocketTransport {
    /// Writes all of `data` to `socket`, retrying on `EINTR` and partial
    /// writes.
    ///
    /// - Parameters:
    ///   - data: The bytes to write.
    ///   - socket: The destination socket descriptor.
    /// - Returns: False on any write failure other than `EINTR`.
    public func writeAll(_ data: Data, to socket: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0

            while offset < rawBuffer.count {
                let written = write(
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
                return false
            }

            return true
        }
    }

    /// Writes all bytes without letting partial progress extend one absolute
    /// command deadline.
    ///
    /// The descriptor is nonblocking only for this synchronous call and its exact
    /// prior flags are restored before returning. Polling in short slices lets
    /// cancellation interrupt a peer that drains its receive buffer too slowly
    /// to reach the deadline in one syscall.
    func writeAll(
        _ data: Data,
        to socket: Int32,
        deadline: TimeInterval,
        isInterrupted: () -> Bool
    ) -> Bool {
        let originalFlags = Darwin.fcntl(socket, F_GETFL, 0)
        guard
            originalFlags >= 0,
            Darwin.fcntl(
                socket,
                F_SETFL,
                originalFlags | O_NONBLOCK
            ) == 0
        else {
            return false
        }
        let writeSucceeded = data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0

            while offset < rawBuffer.count {
                guard !isInterrupted() else { return false }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return false }
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
                guard
                    written < 0,
                    errno == EAGAIN || errno == EWOULDBLOCK
                else {
                    return false
                }

                let remainingMilliseconds = Int32(min(
                    ceil(remaining * 1_000),
                    Double(Int32.max)
                ))
                var descriptor = pollfd(
                    fd: socket,
                    events: Int16(POLLOUT | POLLERR | POLLHUP),
                    revents: 0
                )
                let pollResult = Darwin.poll(
                    &descriptor,
                    1,
                    min(remainingMilliseconds, 50)
                )
                if pollResult < 0, errno == EINTR {
                    continue
                }
                if pollResult == 0 {
                    continue
                }
                guard
                    pollResult > 0,
                    descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL)
                        == 0,
                    descriptor.revents & Int16(POLLOUT) != 0
                else {
                    return false
                }
            }

            return true
        }
        let restoredFlags = Darwin.fcntl(
            socket,
            F_SETFL,
            originalFlags
        )
        return writeSucceeded && restoredFlags == 0
    }

    /// Connects to the listener at `socketPath`, sends one line-terminated
    /// command, and returns the first response line (or nil on any failure or
    /// timeout).
    ///
    /// A blocking client with `SO_RCVTIMEO`/`SO_SNDTIMEO` set to `timeout`;
    /// never polls.
    ///
    /// - Parameters:
    ///   - command: The command text; a trailing newline is appended.
    ///   - socketPath: The Unix-domain socket path to connect to.
    ///   - timeout: Send/receive timeout applied to the probe connection.
    /// - Returns: The first response line without its newline, or nil.
    public func probeCommand(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval
    ) -> String? {
        probeCommandWithPeerProcessID(
            command,
            at: socketPath,
            timeout: timeout
        )?.response
    }

    /// Sends one command and returns both its first response line and the
    /// kernel-reported server process identifier.
    ///
    /// Callers use the peer identity when a response carries an in-memory
    /// secret that must go only to one exact server process generation.
    ///
    /// - Parameters:
    ///   - command: The command text; a trailing newline is appended.
    ///   - socketPath: The Unix-domain socket path to connect to.
    ///   - timeout: Send/receive timeout applied to the probe connection.
    ///   - validatingPeer: Validation performed on the kernel-reported peer PID
    ///     after connecting and before any command bytes are written.
    /// - Returns: The response and peer PID, or nil on connection or I/O failure.
    public func probeCommandWithPeerProcessID(
        _ command: String,
        at socketPath: String,
        timeout: TimeInterval,
        validatingPeer: @Sendable (pid_t?) -> Bool = { _ in true }
    ) -> (response: String, peerProcessID: pid_t?)? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard
            configureUnixClientSocket(
                fd,
                timeout: timeout,
                nonBlocking: false
            ),
            connectUnixSocket(fd, to: socketPath) == 0
        else {
            return nil
        }
        let serverProcessID = peerProcessID(of: fd)
        guard validatingPeer(serverProcessID) else { return nil }

        guard writeAll(Data((command + "\n").utf8), to: fd) else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var responseData = Data()

        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                let readErrno = errno
                if readErrno == EINTR {
                    continue
                }
                if readErrno == EAGAIN || readErrno == EWOULDBLOCK {
                    break
                }
                return nil
            }
            if count == 0 {
                break
            }
            responseData.append(contentsOf: buffer[0..<count])
            if let newlineIndex = responseData.firstIndex(of: 0x0A) {
                guard
                    let response = String(
                        data: responseData[..<newlineIndex],
                        encoding: .utf8
                    )
                else {
                    return nil
                }
                return (
                    response: response,
                    peerProcessID: serverProcessID
                )
            }
        }

        guard let response = String(data: responseData, encoding: .utf8)
        else {
            return nil
        }
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (response: trimmed, peerProcessID: serverProcessID)
    }
}
