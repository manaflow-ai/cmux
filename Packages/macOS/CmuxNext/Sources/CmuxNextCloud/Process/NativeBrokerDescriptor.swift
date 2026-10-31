import Darwin
import Foundation

/// A child-created socket received over the private inherited pair. No filesystem rendezvous.
enum NativeBrokerDescriptor {
    static func pair() throws -> (Int32, Int32) {
        var sockets = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
        do {
            for fd in sockets { try seal(fd) }
        } catch {
            sockets.forEach { Darwin.close($0) }
            throw error
        }
        return (sockets[0], sockets[1])
    }

    /// Called by an owned detached startup task. poll is bounded by a monotonic deadline.
    static func receive(_ socket: Int32) throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while true { // wakeup-allow: bounded startup poll, no periodic or idle wakeup
            let left = clock.now.duration(to: deadline)
            guard left > .zero else { throw POSIXError(.ETIMEDOUT) }
            let ms = left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000
            var event = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            // concurrency-allow: detached startup task only; five-second total deadline.
            let ready = poll(&event, 1, Int32(max(1, min(ms, 5000))))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw POSIXError(ready == 0 ? .ETIMEDOUT : .EIO) }
            return try receiveReady(socket)
        }
    }

    private static func receiveReady(_ socket: Int32) throws -> Int32 {
        var marker: UInt8 = 0
        var control = [UInt64](repeating: 0, count: 8)
        var message = msghdr()
        let count = withUnsafeMutablePointer(to: &marker) { byte in
            var vector = iovec(iov_base: byte, iov_len: 1)
            return withUnsafeMutablePointer(to: &vector) { vector in
                control.withUnsafeMutableBytes { buffer in
                    message.msg_iov = vector; message.msg_iovlen = 1
                    message.msg_control = buffer.baseAddress; message.msg_controllen = socklen_t(buffer.count)
                    return recvmsg(socket, &message, MSG_DONTWAIT)
                }
            }
        }
        var descriptors: [Int32] = []
        var valid = true
        // Darwin's CMSG macros use __DARWIN_ALIGN32, including on arm64.
        let headerSize = (MemoryLayout<cmsghdr>.size + 3) & ~3
        control.withUnsafeBytes { bytes in
            let limit = min(Int(message.msg_controllen), bytes.count)
            var offset = 0
            while offset + headerSize <= limit {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
                let length = Int(header.cmsg_len)
                guard length >= headerSize, length <= limit - offset else { valid = false; break }
                if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS {
                    guard (length - headerSize) % MemoryLayout<Int32>.size == 0 else { valid = false; break }
                    for position in stride(from: offset + headerSize, to: offset + length, by: MemoryLayout<Int32>.size) {
                        descriptors.append(bytes.loadUnaligned(fromByteOffset: position, as: Int32.self))
                    }
                } else { valid = false }
                offset += (length + 3) & ~3
            }
            valid = valid && offset == limit
        }
        guard count == 1, marker == 1, valid, message.msg_flags & MSG_CTRUNC == 0,
              descriptors.count == 1, let fd = descriptors.first, fd >= 0 else {
            descriptors.filter { $0 >= 0 }.forEach { Darwin.close($0) }
            throw POSIXError(.EPROTO)
        }
        do { try seal(fd) } catch { Darwin.close(fd); throw error }
        return fd
    }

    private static func seal(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFD)
        var enabled: Int32 = 1
        guard flags >= 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(.EIO)
        }
    }
}
