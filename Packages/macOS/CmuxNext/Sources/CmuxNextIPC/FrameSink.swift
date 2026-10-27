import Darwin

/// Where a ``FrameWriter`` puts its bytes. The writer calls it only on its own serial drain queue, never on the
/// caller's thread; a sink may wait there (a blocking socket send).
public protocol FrameSink: Sendable {
    /// Sends a prefix of `bytes`, with `fds` as `SCM_RIGHTS` on its first byte when not empty.
    /// - Returns: The bytes sent (0 means no progress), or why the send failed.
    func send(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure>
}

/// A ``FrameSink`` over a connected Unix stream socket: one `sendmsg` per call, the descriptors of a message as
/// `SCM_RIGHTS` with its first byte (Chromium mojo/public/cpp/platform/socket_utils_posix.cc,
/// `SendmsgWithHandles`; cmux-ipc fds.rs `send_with_fds`, the daemon's side). The descriptor stays blocking: the
/// transport's reader thread reads it blocking, and `MSG_DONTWAIT` is not honored for Unix stream sockets on
/// macOS, so only the writer's drain queue waits here. Swift has no `CMSG_*` macros: the layout below is
/// Darwin's (`sys/socket.h`: `__DARWIN_ALIGN32`, data after the aligned `cmsghdr`).
public struct SocketFrameSink: FrameSink {
    /// The socket; the owner closes it after closing the writer.
    public let fd: Int32

    public init(fd: Int32) {
        self.fd = fd
        // A send to a closed peer must fail with EPIPE, not raise SIGPIPE (whose default action ends the
        // process), whatever the caller set. The option fails (EINVAL) once the peer is gone, so sends also
        // pass MSG_NOSIGNAL.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public func send(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        var control = Self.controlMessage(fds)
        var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: bytes.baseAddress), iov_len: bytes.count)
        // wakeup-allow: bounded: repeats only a send that a signal interrupted before it moved any byte
        while true {
            let (sent, code) = withUnsafeMutablePointer(to: &iov) { iovPointer in
                control.withUnsafeMutableBytes { controlBytes -> (Int, Int32) in
                    var header = msghdr()
                    header.msg_iov = iovPointer
                    header.msg_iovlen = 1
                    if !controlBytes.isEmpty {
                        header.msg_control = controlBytes.baseAddress
                        header.msg_controllen = socklen_t(controlBytes.count)
                    }
                    // concurrency-allow: runs only on the FrameWriter's private serial drain queue, never the main thread or the cooperative pool.
                    let sent = Darwin.sendmsg(fd, &header, MSG_NOSIGNAL)
                    return (sent, sent < 0 ? errno : 0)
                }
            }
            if sent >= 0 { return .success(sent) }
            if code == EINTR { continue }
            return .failure(code == EPIPE || code == ECONNRESET ? .peerClosed : .errno(code))
        }
    }

    private static func align(_ length: Int) -> Int { (length + 3) & ~3 }
    private static let headerSpace = align(MemoryLayout<cmsghdr>.size)

    /// One `SCM_RIGHTS` control message holding `fds`, or no bytes when there are none.
    private static func controlMessage(_ fds: [Int32]) -> [UInt8] {
        guard !fds.isEmpty else { return [] }
        let dataLength = MemoryLayout<Int32>.size * fds.count
        var control = [UInt8](repeating: 0, count: headerSpace + align(dataLength))
        control.withUnsafeMutableBytes { bytes in
            let header = cmsghdr(cmsg_len: socklen_t(headerSpace + dataLength), cmsg_level: SOL_SOCKET,
                                 cmsg_type: SCM_RIGHTS)
            bytes.storeBytes(of: header, as: cmsghdr.self)
            for (index, descriptor) in fds.enumerated() {
                bytes.storeBytes(of: descriptor, toByteOffset: headerSpace + index * MemoryLayout<Int32>.size,
                                 as: Int32.self)
            }
        }
        return control
    }
}
