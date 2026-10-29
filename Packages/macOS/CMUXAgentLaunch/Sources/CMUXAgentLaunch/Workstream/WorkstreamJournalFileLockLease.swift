#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owns one acquired journal lock descriptor until the critical section ends.
final class WorkstreamJournalFileLockLease: @unchecked Sendable {
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    func release() {
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
        self.descriptor = nil
    }
}
