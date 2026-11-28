public import CmuxUpdater
import os
import Synchronization

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
        logger.info("\(message, privacy: .public)")
        lines.withLock { lines in
            lines.append(message)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
    }

    public func logPath() -> String {
        "log show --last 1h --predicate 'subsystem == \"com.cmuxterm.app.next\" AND category == \"updater\"'"
    }

    /// The most recent lines, oldest first.
    public var recent: [String] { lines.withLock { $0 } }
}
