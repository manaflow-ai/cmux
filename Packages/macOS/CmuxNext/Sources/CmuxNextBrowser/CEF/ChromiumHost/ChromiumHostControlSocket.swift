#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import Darwin

/// The control socket's non-blocking `sendmsg` and `recvmsg`, with up to
/// ``ChromiumHostControlMessage/maxFds`` descriptors per frame (SCM_RIGHTS).
/// Swift has no `CMSG_*` macros: the layout below is Darwin's
/// (`sys/socket.h`: `__DARWIN_ALIGN32`, data after the aligned `cmsghdr`).
nonisolated struct ChromiumHostControlSocket: Sendable {
    enum ReceiveOutcome: Equatable, Sendable {
        case read(Int)
        case wouldBlock
        case interrupted
        case endOfStream
        /// More descriptors than the control buffer holds (`MSG_CTRUNC`): malformed.
        case truncated
        case failed
    }

    let fd: Int32

    private static func align(_ length: Int) -> Int { (length + 3) & ~3 }
    private static let headerSpace = align(MemoryLayout<cmsghdr>.size)
    /// Room for the descriptors of a few frames in one read.
    static let receiveControlSize = headerSpace + align(MemoryLayout<Int32>.size * ChromiumHostControlMessage.maxFds * 4)

    /// Sends `bytes`, with `fds` on their first byte. Never waits: the descriptor is non-blocking.
    func send(_ bytes: UnsafeRawBufferPointer, fds: [Int32]) -> ChromiumHostControlOutbox.SendOutcome {
        let dataLength = MemoryLayout<Int32>.size * fds.count
        var control = [UInt8](repeating: 0, count: fds.isEmpty ? 0 : Self.headerSpace + Self.align(dataLength))
        var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: bytes.baseAddress), iov_len: bytes.count)
        let (sent, error) = withUnsafeMutablePointer(to: &iov) { iovPointer in
            control.withUnsafeMutableBytes { controlBytes -> (Int, Int32) in
                var header = msghdr()
                header.msg_iov = iovPointer
                header.msg_iovlen = 1
                if !fds.isEmpty {
                    let cmsg = cmsghdr(cmsg_len: socklen_t(Self.headerSpace + dataLength), cmsg_level: SOL_SOCKET,
                                       cmsg_type: SCM_RIGHTS)
                    controlBytes.storeBytes(of: cmsg, as: cmsghdr.self)
                    for (index, descriptor) in fds.enumerated() {
                        controlBytes.storeBytes(of: descriptor, toByteOffset: Self.headerSpace + index * MemoryLayout<Int32>.size,
                                                as: Int32.self)
                    }
                    header.msg_control = controlBytes.baseAddress
                    header.msg_controllen = socklen_t(controlBytes.count)
                }
                let sent = Darwin.sendmsg(fd, &header, 0)
                return (sent, sent < 0 ? errno : 0)
            }
        }
        if sent >= 0 { return .wrote(sent) }
        switch error {
        case EINTR: return .interrupted
        case EAGAIN, EWOULDBLOCK: return .wouldBlock
        case EPIPE, ECONNRESET: return .peerClosed
        default: return .failed
        }
    }

    /// Reads what the socket holds into `chunk`; descriptors that came with
    /// it are appended to `fds` (close-on-exec). Never waits.
    func receive(into chunk: inout [UInt8], control: inout [UInt8], fds: inout [Int32]) -> ReceiveOutcome {
        var received: [Int32] = []
        let (count, error, truncated) = chunk.withUnsafeMutableBytes { chunkBytes in
            control.withUnsafeMutableBytes { controlBytes -> (Int, Int32, Bool) in
                var iov = iovec(iov_base: chunkBytes.baseAddress, iov_len: chunkBytes.count)
                return withUnsafeMutablePointer(to: &iov) { iovPointer -> (Int, Int32, Bool) in
                    var header = msghdr()
                    header.msg_iov = iovPointer
                    header.msg_iovlen = 1
                    header.msg_control = controlBytes.baseAddress
                    header.msg_controllen = socklen_t(controlBytes.count)
                    let count = Darwin.recvmsg(fd, &header, 0)
                    guard count >= 0 else { return (count, errno, false) }
                    var offset = 0
                    let controlLength = Int(header.msg_controllen)
                    while offset + Self.headerSpace <= controlLength {
                        let cmsg = controlBytes.load(fromByteOffset: offset, as: cmsghdr.self)
                        let length = Int(cmsg.cmsg_len)
                        guard length >= Self.headerSpace, offset + length <= controlLength else { break }
                        if cmsg.cmsg_level == SOL_SOCKET, cmsg.cmsg_type == SCM_RIGHTS {
                            let fdCount = (length - Self.headerSpace) / MemoryLayout<Int32>.size
                            for index in 0..<fdCount {
                                let descriptor = controlBytes.load(
                                    fromByteOffset: offset + Self.headerSpace + index * MemoryLayout<Int32>.size, as: Int32.self)
                                _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
                                received.append(descriptor)
                            }
                        }
                        offset += Self.align(length)
                    }
                    return (count, 0, header.msg_flags & MSG_CTRUNC != 0)
                }
            }
        }
        fds.append(contentsOf: received)
        if truncated { return .truncated }
        if count > 0 { return .read(count) }
        if count == 0 { return .endOfStream }
        switch error {
        case EINTR: return .interrupted
        case EAGAIN, EWOULDBLOCK: return .wouldBlock
        case ECONNRESET: return .endOfStream  // the host closed with our frames unread
        default: return .failed
        }
    }
}
#endif
