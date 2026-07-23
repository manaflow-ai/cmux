import Darwin
import Foundation

/// Holds the advisory file lock that serializes one shared Git exclude transaction.
final class ArtifactGitExcludeLease {
    private var descriptor: Int32?

    init(url: URL) throws {
        // `flock` is required here because actor isolation cannot coordinate separate cmux processes.
        let descriptor = Darwin.open(
            url.path,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ArtifactStoreError.gitPrivacyUnavailable(url.path)
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            Darwin.close(descriptor)
            throw ArtifactStoreError.gitPrivacyUnavailable(url.path)
        }
        self.descriptor = descriptor
    }

    func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    deinit {
        release()
    }
}
