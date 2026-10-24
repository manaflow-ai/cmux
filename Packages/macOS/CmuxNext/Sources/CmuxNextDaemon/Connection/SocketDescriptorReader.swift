import Darwin
import Foundation

/// Reads a daemon socket with `recvmsg`, keeping the descriptors that arrive
/// (`SCM_RIGHTS`) in arrival order: a RING frame's ring descriptor rides on
/// its first byte, so the frames that take descriptors take them in that order
/// (plans/cmux-next/app-daemon-connection-DESIGN.md section 4.3). Reader thread only.
nonisolated struct SocketDescriptorReader {
    /// Received descriptors no frame took yet, oldest first.
    private(set) var descriptors: [Int32] = []
    /// Room for 16 descriptors per read; the daemon passes one per RING frame.
    private var control = [UInt8](repeating: 0, count: 256)

    /// One `recvmsg` into `buffer`: its byte count (0 at EOF, -1 with `errno`).
    mutating func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        var received: [Int32] = []
        let count = control.withUnsafeMutableBytes { control -> Int in
            var vector = iovec(iov_base: buffer.baseAddress, iov_len: buffer.count)
            return withUnsafeMutablePointer(to: &vector) { vector -> Int in
                var message = msghdr()
                message.msg_iov = vector
                message.msg_iovlen = 1
                message.msg_control = control.baseAddress
                message.msg_controllen = socklen_t(truncatingIfNeeded: control.count)
                let count = recvmsg(fd, &message, 0)
                guard count >= 0 else { return count }
                received = Self.rights(in: UnsafeRawBufferPointer(control),
                                       length: Int(truncatingIfNeeded: message.msg_controllen))
                return count
            }
        }
        descriptors += received
        return count
    }

    /// The oldest received descriptor, now owned by the caller.
    mutating func take() -> Int32? {
        guard !descriptors.isEmpty else { return nil }
        return descriptors.removeFirst()
    }

    /// Closes every descriptor no frame took (the connection ended).
    mutating func closeAll() {
        for descriptor in descriptors { Darwin.close(descriptor) }
        descriptors.removeAll()
    }

    /// The `SCM_RIGHTS` descriptors in the first `length` bytes of `control`
    /// (Darwin's `cmsghdr`: `len u32, level i32, type i32`, data 4-aligned).
    private static func rights(in control: UnsafeRawBufferPointer, length: Int) -> [Int32] {
        let header = 12
        var descriptors: [Int32] = []
        var offset = 0
        while offset + header <= min(length, control.count) {
            let size = Int(truncatingIfNeeded: control.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            let level = control.loadUnaligned(fromByteOffset: offset + 4, as: Int32.self)
            let type = control.loadUnaligned(fromByteOffset: offset + 8, as: Int32.self)
            guard size >= header, offset + size <= min(length, control.count) else { break }
            if level == SOL_SOCKET, type == SCM_RIGHTS {
                var at = offset + header
                while at + 4 <= offset + size {
                    descriptors.append(control.loadUnaligned(fromByteOffset: at, as: Int32.self))
                    at += 4
                }
            }
            offset += (size + 3) & ~3
        }
        return descriptors
    }
}
