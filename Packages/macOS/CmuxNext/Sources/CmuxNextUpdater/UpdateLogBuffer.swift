public import CmuxUpdater
import os
import CmuxNextCompat

/// The updater's diagnostic trace: unified logging (subsystem
/// `com.cmuxterm.app.next`, category `updater`) plus the last lines in
/// memory for `updates.status`. No file IO, safe from any thread.
nonisolated public final class UpdateLogBuffer: UpdateLogging {
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "updater")
    private let lines = Mutex<[String]>([])
    private let capacity: Int

    public init(capacity: Int = 64) {
        self.capacity = capacity
    }

    public func append(_ message: String) {
        // Notice level stays on disk (`log show` after the app is gone); an info
        // line does not, and the 2026-10-20 slow update left no trace of why
        // its first install failed. Per-chunk progress stays info.
        if Self.isProgress(message) {
            logger.info("\(message, privacy: .public)")
        } else {
            logger.notice("\(message, privacy: .public)")
        }
        lines.withLock { lines in
            lines.append(message)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
    }

    /// Download and extraction progress: many lines per update (each chunk
    /// also logs its state change, `state -> downloading(NN%)`).
    static func isProgress(_ message: String) -> Bool {
        ["download received data", "show extraction progress", "state -> downloading", "state -> extracting"]
            .contains { message.hasPrefix($0) }
    }

    public func logPath() -> String {
        "log show --last 1h --predicate 'subsystem == \"com.cmuxterm.app.next\" AND category == \"updater\"'"
    }

    /// The most recent lines, oldest first.
    public var recent: [String] { lines.withLock { $0 } }
}
