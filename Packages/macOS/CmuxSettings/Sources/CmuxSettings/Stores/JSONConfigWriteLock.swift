import Darwin
import Foundation

/// Cross-process serialization for cmux writers of the same JSON config.
///
/// Actor isolation only serializes one in-process store. The stable sidecar
/// inode is shared with the cmux-settings helper so every participating writer
/// takes the same nonblocking lock before reading the persisted source of truth.
/// Never unlink the sidecar: replacing it would split the lock domain.
struct JSONConfigWriteLock {
    private let descriptor: Int32

    init(target: URL) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        descriptor = Darwin.open(
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

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw JSONConfigWriteConflict.busy
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    func release() {
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}

/// A config mutation that was refused before publication.
enum JSONConfigWriteConflict: Error, Equatable {
    case busy
    case sourceChanged
}
