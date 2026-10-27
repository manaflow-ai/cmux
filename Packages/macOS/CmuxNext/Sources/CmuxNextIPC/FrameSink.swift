import Darwin

/// Where a ``FrameWriter`` puts its bytes. ``send(_:fds:)`` runs only on the writer's serial drain queue and may
/// wait there (a full socket); ``sendWithoutWaiting(_:fds:)`` runs on an enqueuing caller's thread, never the
/// main thread, and must never wait.
public protocol FrameSink: Sendable {
    /// Sends a prefix of `bytes`, with `fds` as `SCM_RIGHTS` on its first byte when not empty.
    /// - Returns: The bytes sent (0 means no progress), or why the send failed.
    func send(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure>

    /// Sends the prefix of `bytes` the sink takes now, `fds` with its first byte, without waiting
    /// (the inline write of p05-ipc-140).
    /// - Returns: The bytes sent, 0 when nothing can go now (the message then waits for the drain), or why the
    ///   send failed.
    func sendWithoutWaiting(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure>
}

extension FrameSink {
    /// A sink that cannot send without waiting takes nothing inline: every message goes to the drain queue.
    public func sendWithoutWaiting(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        .success(0)
    }
}

/// A ``FrameSink`` over a connected Unix stream socket: one `sendmsg` per call, the descriptors of a message as
/// `SCM_RIGHTS` with its first byte (Chromium mojo/public/cpp/platform/socket_utils_posix.cc,
/// `SendmsgWithHandles`; cmux-ipc fds.rs `send_with_fds`, the daemon's side). `MSG_DONTWAIT` is not honored for
/// Unix stream sockets on macOS, so only a socket the owner set `O_NONBLOCK` on sends inline
/// (``sendWithoutWaiting(_:fds:)``); on it ``send(_:fds:)`` waits for room with `poll`, on the drain queue only.
/// A blocking socket takes nothing inline. Swift has no `CMSG_*` macros: the layout below is Darwin's
/// (`sys/socket.h`: `__DARWIN_ALIGN32`, data after the aligned `cmsghdr`).
public struct SocketFrameSink: FrameSink {
    /// The socket; the owner closes it after closing the writer.
    public let fd: Int32
    /// The socket was nonblocking when the sink was made: a send never waits in the kernel.
    private let nonblocking: Bool

    public init(fd: Int32) {
        self.fd = fd
        nonblocking = fcntl(fd, F_GETFL) & O_NONBLOCK != 0
        // A send to a closed peer must fail with EPIPE, not raise SIGPIPE (whose default action ends the
        // process), whatever the caller set. The option fails (EINVAL) once the peer is gone, so sends also
        // pass MSG_NOSIGNAL.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public func send(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        // wakeup-allow: bounded: repeats a send only after the socket reported room, a hang-up or an error
        while true {
            switch sendOnce(bytes, fds: fds) {
            case .success(let sent?): return .success(sent)
            case .success(nil):
                if let failure = waitForRoom() { return .failure(failure) }
            case .failure(let failure): return .failure(failure)
            }
        }
    }

    public func sendWithoutWaiting(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        guard nonblocking else { return .success(0) }
        return sendOnce(bytes, fds: fds).map { $0 ?? 0 }
    }

    /// One `sendmsg`, repeated only when a signal interrupted it before it moved a byte.
    /// - Returns: The bytes sent; nil when a nonblocking socket has no room (EAGAIN).
    private func sendOnce(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int?, FrameWriter.Failure> {
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
                    // concurrency-allow: a blocking socket is sent only from the FrameWriter's private serial drain queue; a nonblocking one never waits, and the FrameWriter never sends from the main thread.
                    let sent = Darwin.sendmsg(fd, &header, MSG_NOSIGNAL)
                    return (sent, sent < 0 ? errno : 0)
                }
            }
            if sent >= 0 { return .success(sent) }
            if code == EINTR { continue }
            if code == EAGAIN { return .success(nil) }
            return .failure(code == EPIPE || code == ECONNRESET ? .peerClosed : .errno(code))
        }
    }

    /// Waits on the drain queue until the nonblocking socket takes more bytes, hangs up or fails; the next send
    /// reports which. Chromium's IO thread waits the same way, for the fd to be writable
    /// (mojo/core/channel_posix.cc, `OnFileCanWriteWithoutBlocking`).
    private func waitForRoom() -> FrameWriter.Failure? {
        var poller = pollfd(fd: fd, events: Int16(clamping: POLLOUT), revents: 0)
        // wakeup-allow: bounded: an event wait with no timeout; the owner's shutdown ends it with POLLHUP
        while true {
            // concurrency-allow: runs only on the FrameWriter's private serial drain queue, never the main thread or the cooperative pool.
            let ready = poll(&poller, 1, -1)
            if ready > 0 {
                return poller.revents & Int16(clamping: POLLNVAL) != 0 ? .errno(EBADF) : nil
            }
            if ready < 0, errno != EINTR { return .errno(errno) }
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
