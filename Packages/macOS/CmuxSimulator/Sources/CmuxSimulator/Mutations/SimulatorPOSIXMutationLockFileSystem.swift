import Darwin
import Foundation

/// POSIX implementation shared by the cmux host and isolated Simulator workers.
package struct SimulatorPOSIXMutationLockFileSystem: SimulatorMutationLockFileSystem {
    /// Creates the stateless POSIX filesystem adapter.
    package init() {}

    /// User-private directory for cross-process mutation locks.
    package var defaultLockDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-simulator-mutations", isDirectory: true)
    }

    /// Creates and validates the user-owned lock directory.
    package func prepareLockDirectory(_ directory: URL) throws {
        let result = directory.path.withCString {
            Darwin.mkdir($0, S_IRWXU)
        }
        if result != 0, errno != EEXIST { throw currentPOSIXError() }

        var metadata = stat()
        guard directory.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            throw currentPOSIXError()
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid() else {
            throw POSIXError(.EACCES)
        }
        guard directory.path.withCString({ Darwin.chmod($0, S_IRWXU) }) == 0 else {
            throw currentPOSIXError()
        }
    }

    /// Opens and validates one non-inheritable regular lock file.
    package func openLockFile(_ url: URL) throws -> Int32 {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        do {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw currentPOSIXError() }
            guard metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == geteuid() else {
                throw POSIXError(.EACCES)
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw currentPOSIXError()
            }
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                throw currentPOSIXError()
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    /// Attempts to acquire the lock without pinning a thread behind another process.
    package func tryLock(_ descriptor: Int32) throws -> Bool {
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            if errno == EWOULDBLOCK { return false }
            if errno != EINTR { throw currentPOSIXError() }
        }
    }

    /// Releases an exclusive advisory lock.
    package func unlock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
    }

    /// Closes a lock-file descriptor.
    package func close(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
