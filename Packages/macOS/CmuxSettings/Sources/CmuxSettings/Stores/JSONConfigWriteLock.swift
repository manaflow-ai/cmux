import Darwin
import Dispatch
import Foundation

/// Cross-process serialization for cmux writers of the same JSON config.
///
/// Actor isolation only serializes one in-process store. The stable sidecar
/// inode is shared with the cmux-settings helper so every participating writer
/// takes the same kernel lock before reading the persisted source of truth.
/// Lock acquisition waits off the settings actor and resumes when the kernel
/// grants ownership. Never unlink the sidecar: replacing it would split the
/// lock domain.
struct JSONConfigWriteLock: Sendable {
    private static let waitQueue = DispatchQueue(
        label: "com.cmux.settings.json-write-lock",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let descriptor: Int32

    static func acquire(target: URL) async throws -> JSONConfigWriteLock {
        try await withCheckedThrowingContinuation { continuation in
            waitQueue.async {
                continuation.resume(with: Result {
                    try JSONConfigWriteLock(blockingTarget: target)
                })
            }
        }
    }

    private init(blockingTarget target: URL) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = Darwin.open(
            target.path + ".cmux-write.lock",
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw POSIXError(.EPERM)
        }

        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            guard code == EINTR else {
                Darwin.close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        self.descriptor = descriptor
    }

    func release() {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

/// A config mutation that was refused before publication.
enum JSONConfigWriteConflict: Error, Equatable {
    case sourceChanged
    case sourceChangedRollbackFailed(rollbackErrno: Int32)
}
