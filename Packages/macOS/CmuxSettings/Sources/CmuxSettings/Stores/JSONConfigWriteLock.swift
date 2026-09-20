import Darwin
import Foundation

/// Cross-process coordination for the native store and cmux-settings helper.
///
/// Actor isolation cannot coordinate processes. Nonblocking flock avoids holding
/// a cooperative executor thread while another process validates. Never unlink
/// the sidecar: replacing its inode would split the coordination domain.
struct JSONConfigWriteLock {
    private let descriptor: Int32

    init(target: URL) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = Darwin.open(target.path + ".cmux-write.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw POSIXError(.EPERM)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { throw JSONConfigMutationError.busy }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    func release() {
        // Explicit unlock also releases any transient inherited descriptor while
        // another thread is spawning a child; close-on-exec alone is too late.
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
