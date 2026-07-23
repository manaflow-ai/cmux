import Darwin
import Foundation

/// Serializes artifact mutations across the app and standalone CLI processes.
final class ArtifactStoreMutationLease {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Uses the already-managed artifact directory because actor isolation cannot
    /// coordinate independent processes and acquisition must not create a new path.
    static func acquire(directory: URL) throws -> ArtifactStoreMutationLease {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw ArtifactStoreError.pathOutsideStore(directory.path)
        }
        var keepsDescriptor = false
        defer {
            if !keepsDescriptor {
                _ = close(descriptor)
            }
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR else {
            throw ArtifactStoreError.pathOutsideStore(directory.path)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw ArtifactStoreError.storeBusy(directory.path)
            }
            throw ArtifactStoreError.pathOutsideStore(directory.path)
        }
        keepsDescriptor = true
        return ArtifactStoreMutationLease(descriptor: descriptor)
    }

    func finish() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        descriptor = -1
    }

    deinit {
        finish()
    }
}
