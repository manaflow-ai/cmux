public import CmuxUpdater
import os
import CmuxNextCompat

/// The updater's diagnostic trace: unified logging (subsystem
/// `com.cmuxterm.app.next`, category `updater`), the last lines in
/// memory for `updates.status`, and, given one, the file on disk
/// (``UpdateLogFile``, written off the caller's thread). Safe from any thread.
nonisolated public final class UpdateLogBuffer: UpdateLogging {
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "updater")
    private let lines = Mutex<[String]>([])
    private let capacity: Int
    /// The trace on disk, or nil (tests, demos).
    public let file: UpdateLogFile?

    public init(capacity: Int = 64, file: UpdateLogFile? = nil) {
        self.capacity = capacity
        self.file = file
    }

    public func append(_ message: String) {
        // Notice, not info: info lines are not kept, so a slow install could not be traced (a583).
        logger.notice("\(message, privacy: .public)")
        file?.write(message)
        lines.withLock { lines in
            lines.append(message)
            if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        }
    }

    public func logPath() -> String {
        if let file { return file.url.path }
        return "log show --last 1h --predicate 'subsystem == \"com.cmuxterm.app.next\" AND category == \"updater\"'"
    }

    /// The most recent lines, oldest first.
    public var recent: [String] { lines.withLock { $0 } }
}
