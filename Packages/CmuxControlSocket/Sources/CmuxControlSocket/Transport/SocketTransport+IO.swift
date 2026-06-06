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
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        configureSocketTimeouts(fd, timeout: timeout)

        _ = configureNoSigPipe(fd)

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            memset(raw, 0, maxLen)
            for index in 0..<pathBytes.count {
                raw[index] = pathBytes[index]
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + pathBytes.count)
#if os(macOS)
        addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else { return nil }

        guard writeAll(Data((command + "\n").utf8), to: fd) else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var response = ""

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
            if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                response.append(chunk)
                if let newlineIndex = response.firstIndex(of: "\n") {
                    return String(response[..<newlineIndex])
                }
            }
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
