import Darwin
import Foundation

/// Holds the shared filesystem lease for one prepared diff-viewer session.
final class CmuxDiffViewerSessionLease: Sendable {
    private let fileDescriptor: Int32

    init(root: URL, token: String) throws {
        let path = root.appendingPathComponent(".session-lease-\(token).lock").path
        fileDescriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard fileDescriptor >= 0, flock(fileDescriptor, LOCK_SH | LOCK_NB) == 0 else {
            if fileDescriptor >= 0 { Darwin.close(fileDescriptor) }
            throw POSIXError(.EWOULDBLOCK)
        }
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
    }
}
