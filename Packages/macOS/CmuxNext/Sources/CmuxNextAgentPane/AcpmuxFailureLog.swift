import CmuxNextCompat
import Foundation
import os

/// Writes why the app could not reach acpmux into the log the banner names
/// (`daemon.log`), so that log has the cause even when the daemon itself saw
/// nothing (a peer the app refused never reaches the daemon). The line is in
/// acpmux's own format with level `ERROR`, so the error journal (`cmux errors`)
/// harvests it with the daemon's lines. Each cause is written once per log per
/// app process: the page retries every few seconds and must not flood the log.
nonisolated struct AcpmuxFailureLog: Sendable {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.acpmux")
    // A synchronous set insert from any isolation; no suspension is wanted here.
    private static let written = Mutex<Set<String>>([])

    let logPath: String
    let now: @Sendable () -> Date
    /// Runs after the log is open for this line and before the line is written (tests put another
    /// writer's whole line there, the interleaving of two writers at once).
    let beforeWrite: @Sendable () -> Void

    init(logPath: String, now: @escaping @Sendable () -> Date = Date.init, beforeWrite: @escaping @Sendable () -> Void = {}) {
        self.logPath = logPath
        self.beforeWrite = beforeWrite
        self.now = now
    }

    /// The line written for `cause`, with `detail` (a pid, a refusal) appended.
    func line(_ cause: AcpmuxFailureCause, detail: String) -> String {
        let stamp = now().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let tail = detail.isEmpty ? "" : " (\(detail))"
        return "\(stamp)  ERROR cmux app: cannot reach acpmux: \(cause.logText)\(tail)\n"
    }

    /// Appends the line for `cause` unless this process already wrote it to this log.
    /// Returns whether it wrote.
    @discardableResult
    func record(_ cause: AcpmuxFailureCause, detail: String) -> Bool {
        Self.logger.error("cannot reach acpmux: \(cause.logText, privacy: .public) \(detail, privacy: .public) log=\(logPath, privacy: .public)")
        guard Self.written.withLock({ $0.insert("\(logPath)|\(cause)").inserted }) else { return false }
        // One write on an O_APPEND descriptor: the kernel puts each line at the end as it is then,
        // so two writers at once (a person's restart and the lookup it ends, #28083) never write
        // over each other, as a seek to the end and a later write did. Only an existing log.
        let descriptor = open(logPath, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let bytes = Array(line(cause, detail: detail).utf8)
        beforeWrite()
        return bytes.withUnsafeBytes { blockingWrite(descriptor, $0.baseAddress, $0.count) } == bytes.count
    }
}
