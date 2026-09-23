import CryptoKit
import Darwin
import Foundation

/// Serializes managed restore launches across cmux app instances for one account and conversation.
///
/// The CLI owns this resource synchronously and transfers its descriptor through exec.
/// It is deliberately not Sendable: only the restoring process manipulates its lifetime.
public final class AgentRestoreLaunchLease {
    private var descriptor: Int32

    /// Creates or opens a persistent lease inode in an injected private directory.
    ///
    /// - Parameters:
    ///   - directory: Shared per-user directory, independent of the cmux bundle identifier.
    ///   - account: Canonical provider state directory.
    ///   - sessionID: The exact conversation identifier.
    ///   - fileManager: Filesystem adapter used to prepare the private directory.
    /// - Throws: A POSIX error when the private lease cannot be opened safely.
    public init(directory: URL, account: String, sessionID: String, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o077 == 0 else {
            throw POSIXError(.EACCES)
        }
        let key = account + "\0" + (UUID(uuidString: sessionID)?.uuidString.lowercased() ?? sessionID)
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = directory.appendingPathComponent(digest + ".lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EACCES)
        }
        descriptor = fd
    }

    /// Attempts acquisition without blocking the restoring CLI.
    /// - Returns: False only when another process holds the same lease.
    /// - Throws: A POSIX error for an unavailable lease.
    public func tryAcquire() throws -> Bool {
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
        if errno == EWOULDBLOCK { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    /// Waits in the kernel for the preceding managed launch to release ownership.
    ///
    /// This synchronous boundary is for the restoring CLI process, never the app.
    /// No timer, PID guess, file deletion, or signal to the other owner is involved.
    /// - Throws: A POSIX error if acquisition is interrupted or fails.
    public func acquireAfterOwnerExit() throws {
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// Keeps ownership through wrapper execs until the launched process closes its descriptor.
    /// - Throws: A POSIX error if descriptor inheritance cannot be enabled.
    public func inheritAcrossExec() throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Releases this descriptor. The inode remains so queued contenders cannot split ownership.
    public func release() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
