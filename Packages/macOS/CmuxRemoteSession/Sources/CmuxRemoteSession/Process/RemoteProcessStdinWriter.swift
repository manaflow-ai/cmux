internal import Darwin
internal import Foundation

struct RemoteProcessStdinWriter: RemoteProcessStdinWriting {
    func write(
        _ data: Data,
        to handle: FileHandle,
        stopFileDescriptor: Int32
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
                var readiness = [
                    pollfd(
                        fd: descriptor,
                        events: Int16(POLLOUT | POLLERR | POLLHUP),
                        revents: 0
                    ),
                    pollfd(
                        fd: stopFileDescriptor,
                        events: Int16(POLLIN | POLLERR | POLLHUP),
                        revents: 0
                    ),
                ]
                let pollResult = Darwin.poll(&readiness, nfds_t(readiness.count), -1)
                if pollResult < 0 {
                    let code = errno
                    if code == EINTR {
                        continue
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                }
                if readiness[1].revents != 0 {
                    return
                }
                if (readiness[0].revents & Int16(POLLNVAL)) != 0 {
                    throw POSIXError(.EBADF)
                }

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
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
    }
}
