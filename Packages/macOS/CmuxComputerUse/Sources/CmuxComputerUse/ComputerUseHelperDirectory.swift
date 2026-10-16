import Darwin
import Foundation

/// Admits one filesystem transaction for a private helper scope across processes.
struct ComputerUseHelperDirectory {
    private let fileManager: FileManager

    nonisolated init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Holds a nonblocking process lease through the synchronous transaction.
    /// An actor cannot exclude another cmux process using the same helper scope;
    /// `flock(LOCK_NB)` never blocks a thread and the kernel releases it on exit.
    nonisolated func withExclusiveAccess<Result>(
        to directory: URL,
        createIfMissing: Bool,
        operation: () throws -> Result
    ) throws -> Result {
        if createIfMissing {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw currentError() }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw currentError() }
        guard metadata.st_uid == geteuid() else { throw POSIXError(.EPERM) }
        if metadata.st_mode & 0o777 != 0o700 {
            guard fchmod(descriptor, 0o700) == 0 else { throw currentError() }
        }
        let lease = openat(
            descriptor, ".cmux-cua-install.lock",
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600
        )
        guard lease >= 0 else { throw currentError() }
        defer { Darwin.close(lease) }
        guard fstat(lease, &metadata) == 0 else { throw currentError() }
        guard metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & 0o777 == 0o600
        else { throw POSIXError(.EPERM) }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw currentError() }
        defer { flock(lease, LOCK_UN) }
        return try operation()
    }

    /// Captures errno before another filesystem call can overwrite it.
    private nonisolated func currentError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
