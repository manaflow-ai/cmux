import Foundation

/// Enforces one injected monotonic deadline across bounded Claude task I/O.
struct ClaudeTaskOperationDeadline {
    private let deadlineUptime: TimeInterval?
    private let uptime: @Sendable () -> TimeInterval

    /// Creates an optional deadline backed by an injectable monotonic clock.
    init(
        deadlineUptime: TimeInterval?,
        uptime: @escaping @Sendable () -> TimeInterval
    ) {
        self.deadlineUptime = deadlineUptime
        self.uptime = uptime
    }

    /// Throws once the operation has exhausted its caller-owned time budget.
    func check() throws {
        guard let deadlineUptime else { return }
        guard uptime() < deadlineUptime else {
            throw ClaudeTaskSnapshotLoaderError.operationDeadlineExceeded
        }
    }
}
