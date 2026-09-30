import Darwin
public import Foundation

/// Writes attach output without preventing signal-driven terminal restoration.
///
/// One foreground attach owns this writer. The original descriptor flags are
/// restored on destruction, including flags shared with an inherited descriptor.
public final class SSHPTYOutputWriter {
    private let descriptor: Int32
    private let originalFlags: Int32
    private let isSocket: Bool
    private let originalNoSIGPIPE: Int32

    /// Borrows the foreground attach's output descriptor until destruction.
    /// - Parameter fileDescriptor: Output descriptor, normally stdout.
    /// - Throws: A POSIX error if nonblocking output cannot be configured.
    public init(fileDescriptor: Int32) throws {
        descriptor = dup(fileDescriptor)
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        originalFlags = fcntl(descriptor, F_GETFL)
        originalNoSIGPIPE = fcntl(descriptor, F_GETNOSIGPIPE)
        var status = stat()
        isSocket = fstat(descriptor, &status) == 0
            && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
        guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw error
        }
        if !isSocket { _ = fcntl(descriptor, F_SETNOSIGPIPE, 1) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        if !isSocket, originalNoSIGPIPE >= 0 { _ = fcntl(descriptor, F_SETNOSIGPIPE, originalNoSIGPIPE) }
        _ = fcntl(descriptor, F_SETFL, originalFlags)
        Darwin.close(descriptor)
    }

    /// Delivers bytes or stops when output closes or the attach is cancelled.
    /// - Parameters:
    ///   - data: Bytes to deliver in order.
    ///   - cancellation: The attach's signal monitor.
    /// - Returns: Whether all bytes were delivered.
    public func write(_ data: Data, cancellation: SSHPTYAttachSignalMonitor) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                guard cancellation.cancellationSignal == nil else { return false }
                let pointer = base.advanced(by: offset)
                let count = isSocket
                    ? Darwin.send(descriptor, pointer, bytes.count - offset, MSG_NOSIGNAL)
                    : Darwin.write(descriptor, pointer, bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard cancellation.waitUntilWritable(descriptor) else { return false }
                    continue
                }
                return false
            }
            return true
        }
    }
}
