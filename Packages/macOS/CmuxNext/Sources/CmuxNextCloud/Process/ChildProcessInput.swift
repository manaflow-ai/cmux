import Darwin
import Foundation

/// One bounded secret sent to the child's stdin, never argv, environment or disk.
final class ChildProcessInput {
    let pipe = Pipe()
    private let data: Data

    init(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 16_384 else { throw CocoaError(.fileReadTooLarge) }
        self.data = data
    }

    /// Called only after launch. A detached writer avoids blocking the actor
    /// when the pipe fills; closing the child's read end releases it on exit.
    func send() throws {
        let fd = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        do {
            try pipe.fileHandleForReading.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            close(fd)
            throw error
        }
        let data = data
        // task-owner: this writer owns fd until EOF/error; the bounded hub
        // startup deadline ends a child that never consumes its input.
        Task.detached {
            defer { close(fd) }
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count }
                    else if count < 0, errno == EINTR { continue }
                    else { break }
                }
            }
        }
    }
}
