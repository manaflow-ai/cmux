import Darwin
import Dispatch
import Foundation

/// Cross-process serialization for cmux writers of the same JSON config.
///
/// Actor isolation only serializes one in-process store. The stable sidecar
/// inode is shared with the cmux-settings helper so every participating writer
/// takes the same bounded-wait lock before reading the persisted source of truth.
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

        // Ordinary overlapping cmux writes should serialize, then re-read
        // the authoritative file under the lock. Bound the wait so a wedged
        // helper/editor path cannot pin a synchronous settings call forever.
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN else {
                Darwin.close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                Darwin.close(descriptor)
                throw JSONConfigWriteConflict.busy
            }
            usleep(10_000)
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
