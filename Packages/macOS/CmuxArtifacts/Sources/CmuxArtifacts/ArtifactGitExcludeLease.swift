import Darwin
import Foundation

/// Holds the advisory file lock that serializes one shared Git exclude transaction.
final class ArtifactGitExcludeLease {
    private static let maximumWait: Duration = .milliseconds(300)
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
        var keepsDescriptor = false
        defer {
            if !keepsDescriptor {
                Darwin.close(descriptor)
            }
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw ArtifactStoreError.pathOutsideStore(url.path)
        }
        try Task.checkCancellation()
        let deadline = ContinuousClock.now.advanced(by: Self.maximumWait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
                throw ArtifactStoreError.gitPrivacyUnavailable(url.path)
            }
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw ArtifactStoreError.gitPrivacyUnavailable(url.path)
            }
            // `flock` has no wake-up notification; this bounded backoff avoids a hot spin.
            var delay = timespec(tv_sec: 0, tv_nsec: 5_000_000)
            var remainder = timespec()
            while nanosleep(&delay, &remainder) != 0 {
                guard errno == EINTR else {
                    throw ArtifactStoreError.gitPrivacyUnavailable(url.path)
                }
                try Task.checkCancellation()
                delay = remainder
            }
        }
        keepsDescriptor = true
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
