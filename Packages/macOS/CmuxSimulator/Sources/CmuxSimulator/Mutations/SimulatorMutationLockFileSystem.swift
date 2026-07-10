import Darwin
import Foundation

/// Filesystem and advisory-lock operations used by ``SimulatorMutationGate``.
package protocol SimulatorMutationLockFileSystem: Sendable {
    /// Returns the user-private directory shared by host and worker processes.
    var defaultLockDirectory: URL { get }
    /// Creates or validates the private lock directory.
    func prepareLockDirectory(_ directory: URL) throws
    /// Opens one regular lock file without allowing descriptor inheritance.
    func openLockFile(_ url: URL) throws -> Int32
    /// Blocks the calling helper thread until it owns an exclusive advisory lock.
    func lock(_ descriptor: Int32) throws
    /// Releases an acquired advisory lock.
    func unlock(_ descriptor: Int32)
    /// Closes an open lock descriptor.
    func close(_ descriptor: Int32)
}

/// POSIX implementation shared by the cmux host and isolated Simulator workers.
package struct SimulatorPOSIXMutationLockFileSystem: SimulatorMutationLockFileSystem {
    package init() {}

    package var defaultLockDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("cmux-simulator-mutations", isDirectory: true)
    }

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

    package func lock(_ descriptor: Int32) throws {
        while true {
            if flock(descriptor, LOCK_EX) == 0 { return }
            if errno != EINTR { throw currentPOSIXError() }
        }
    }

    package func unlock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
    }

    package func close(_ descriptor: Int32) {
        _ = Darwin.close(descriptor)
    }

    private func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
