import Darwin
import Foundation

/// Keeps the socket alive until all queued cancellation callbacks release it.
final class SSHPTYShutdownDescriptor: Sendable {
    private let fd: Int32

    init(_ bridgeFD: Int32) throws {
        fd = dup(bridgeFD)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { Darwin.close(fd) }

    func shutdown() { _ = Darwin.shutdown(fd, SHUT_RDWR) }
}
