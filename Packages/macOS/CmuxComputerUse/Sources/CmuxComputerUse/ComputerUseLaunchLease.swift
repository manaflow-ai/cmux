import Darwin
import Foundation

/// Cross-process admission for one cmux-cua runtime scope.
///
/// The in-process lifecycle task cannot serialize two cmux app instances that
/// share the same installed helper, sockets, and PID files. This kernel lock
/// covers the complete health/stop/install/launch handoff so a second host
/// cannot truncate the PID file or unlink the socket while the first launches.
final class ComputerUseLaunchLease {
    private var descriptor: Int32 = -1

    init(runtimeDirectory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = runtimeDirectory.appendingPathComponent("launch.lock").path
        let fd = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(0o600)
        )
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var metadata = stat()
        guard Darwin.fstat(fd, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o600)
        else {
            Darwin.close(fd)
            throw POSIXError(.EACCES)
        }
        descriptor = fd
    }

    func tryAcquire() throws -> Bool {
        guard descriptor >= 0 else { throw POSIXError(.EBADF) }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
