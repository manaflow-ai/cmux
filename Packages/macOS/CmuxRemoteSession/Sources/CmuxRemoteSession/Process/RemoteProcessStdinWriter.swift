internal import Darwin
internal import Foundation

struct RemoteProcessStdinWriter: RemoteProcessStdinWriting {
    func write(
        _ data: Data,
        to handle: FileHandle,
        shouldStop: @escaping @Sendable () -> Bool
    ) throws {
        let descriptor = handle.fileDescriptor
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                if shouldStop() { return }

                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }

                let code = written == 0 ? EIO : errno
                if code == EINTR {
                    continue
                }
                if code == EAGAIN || code == EWOULDBLOCK {
                    var readiness = pollfd(
                        fd: descriptor,
                        events: Int16(POLLOUT),
                        revents: 0
                    )
                    let pollResult = Darwin.poll(&readiness, 1, 25)
                    if pollResult >= 0 || errno == EINTR {
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
    }
}
