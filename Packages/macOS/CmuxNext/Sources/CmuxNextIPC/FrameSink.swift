import Darwin

/// Where a ``FrameWriter`` puts its bytes. The writer calls ``send(_:fds:)`` only on its own serial drain queue,
/// never on the caller's thread; a sink may wait there (a blocking socket send). ``trySend(_:fds:)`` is the inline
/// write of an idle writer: it runs on the caller's thread, never the main thread, and never waits.
public protocol FrameSink: Sendable {
    /// Sends a prefix of `bytes`, with `fds` as `SCM_RIGHTS` on its first byte when not empty.
    /// - Returns: The bytes sent (0 means no progress), or why the send failed.
    func send(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure>

    /// The largest message ``trySend(_:fds:)`` takes; 0 when the sink has no inline path.
    var inlineLimit: Int { get }

    /// Whether ``trySend(_:fds:)`` takes a message of `byteCount` bytes carrying `fdCount` descriptors: what the
    /// message costs the socket (its bytes and its descriptors' control data) fits in ``inlineLimit``.
    func takesInline(byteCount: Int, fdCount: Int) -> Bool

    /// One send of a prefix of `bytes` that never waits for room, with `fds` on its first byte when it sends
    /// any; a message that ``takesInline(byteCount:fdCount:)`` refuses sends nothing.
    /// - Returns: The bytes sent, 0 when there was no room, or why the send failed.
    func trySend(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure>
}

extension FrameSink {
    /// No inline path: every message goes through the drain queue.
    public var inlineLimit: Int { 0 }

    public func takesInline(byteCount: Int, fdCount: Int) -> Bool { byteCount <= inlineLimit }

    public func trySend(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        .success(0)
    }
}

/// A ``FrameSink`` over a connected Unix stream socket: one `sendmsg` per call, the descriptors of a message as
/// `SCM_RIGHTS` with its first byte (Chromium mojo/public/cpp/platform/socket_utils_posix.cc,
/// `SendmsgWithHandles`; cmux-ipc fds.rs `send_with_fds`, the daemon's side). The descriptor stays blocking: the
/// transport's reader thread reads it blocking, and `MSG_DONTWAIT` is not honored for Unix stream sockets on
/// macOS, so only the writer's drain queue waits here. Swift has no `CMSG_*` macros: the layout below is
/// Darwin's (`sys/socket.h`: `__DARWIN_ALIGN32`, data after the aligned `cmsghdr`).
///
/// ``trySend(_:fds:)`` sends only when `poll` reports room: XNU's `sosend` does not wait when the room
/// (`sbspace`, at least the send low-water mark that makes the socket writable, `sowriteable`) holds the whole
/// message, so a message of at most ``inlineLimit`` (that mark, raised to ``inlineLowWater``) leaves in one pass.
/// The room a message needs is its bytes plus its `SCM_RIGHTS` control data: `sosend` takes the control length
/// out of the room before it copies the data, and waits for the rest when the two do not fit.
public struct SocketFrameSink: FrameSink {
    /// The send low-water mark the inline path asks for: room for a key, a resize or a request.
    public static let inlineLowWater = 64 << 10

    /// The socket; the owner closes it after closing the writer.
    public let fd: Int32
    /// The socket's send low-water mark: the most room (bytes and control data) a message ``trySend(_:fds:)``
    /// sends may need.
    public let inlineLimit: Int

    public init(fd: Int32) {
        self.fd = fd
        // A send to a closed peer must fail with EPIPE, not raise SIGPIPE (whose default action ends the
        // process), whatever the caller set. The option fails (EINVAL) once the peer is gone, so sends also
        // pass MSG_NOSIGNAL.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        inlineLimit = Self.raiseLowWater(fd)
    }

    public func send(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        sendMessage(bytes, fds: fds, flags: MSG_NOSIGNAL)
    }

    /// The bytes plus the control data of its descriptors fit in the low-water mark that `poll` guarantees.
    public func takesInline(byteCount: Int, fdCount: Int) -> Bool {
        byteCount + Self.controlSpace(fdCount: fdCount) <= inlineLimit
    }

    public func trySend(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> Result<Int, FrameWriter.Failure> {
        guard takesInline(byteCount: bytes.count, fdCount: fds.count) else { return .success(0) }
        var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        // SAFETY: poll reads and writes the one pollfd it is given, a local live for the call; timeout 0 never waits.
        let polled = unsafe poll(&ready, 1, 0)
        guard polled > 0, ready.revents & Int16(POLLOUT) != 0 else { return .success(0) }
        switch sendMessage(bytes, fds: fds, flags: MSG_NOSIGNAL | MSG_DONTWAIT) {
        case .failure(.errno(let code)) where code == EAGAIN: return .success(0)
        case let result: return result
        }
    }

    /// Asks for ``inlineLowWater`` as the send low-water mark and returns the mark the socket holds (0 when it
    /// reports none, which turns the inline path off).
    private static func raiseLowWater(_ fd: Int32) -> Int {
        var mark = Int32(clamping: inlineLowWater)
        let size = socklen_t(MemoryLayout<Int32>.size)
        // SAFETY: setsockopt reads `size` bytes, MemoryLayout<Int32>.size, from `mark`, an Int32 live for the call.
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &mark, size)
        var length = size
        // SAFETY: getsockopt writes at most `length` bytes into `mark`, an Int32 live for the call.
        guard unsafe getsockopt(fd, SOL_SOCKET, SO_SNDLOWAT, &mark, &length) == 0 else { return 0 }
        return max(0, Int(mark))
    }

    private func sendMessage(_ bytes: UnsafeRawBufferPointer, fds: [Int32], flags: Int32) -> Result<Int, FrameWriter.Failure> {
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
                    // concurrency-allow: never waits on the caller's thread: a blocking send runs only on the FrameWriter's private serial drain queue; trySend's runs off the main thread after poll found room for the whole message.
                    let sent = Darwin.sendmsg(fd, &header, flags)
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

    /// The length of the `SCM_RIGHTS` control message of `fdCount` descriptors (`CMSG_SPACE`), 0 for none.
    public static func controlSpace(fdCount: Int) -> Int {
        fdCount > 0 ? headerSpace + align(MemoryLayout<Int32>.size * fdCount) : 0
    }

    /// One `SCM_RIGHTS` control message holding `fds`, or no bytes when there are none.
    private static func controlMessage(_ fds: [Int32]) -> [UInt8] {
        guard !fds.isEmpty else { return [] }
        let dataLength = MemoryLayout<Int32>.size * fds.count
        var control = [UInt8](repeating: 0, count: controlSpace(fdCount: fds.count))
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
