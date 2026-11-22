public import Foundation

/// The session owner is still restoring: one progress line of `server ensure --restore-progress`
/// (`{"progress":"restoring","session":…,"pid":…,"waited_ms":…}`, every 5 s, cmux-tui `print_progress`).
/// The app shows it while it waits (Leo, 2026-11-08: a 30-minute restore read only "cmux's background
/// service isn't connected"), in ``EnsureOutcome/restoring``.
public struct RestoreProgressReport: Sendable, Equatable {
    public var session: String
    /// The owner's pid; nil when the ensure does not know it yet.
    public var pid: Int32?
    /// How long the ensure has waited on the restore.
    public var waitedMs: UInt64
    /// When the line arrived.
    public var updatedAt: Date

    public init(session: String, pid: Int32?, waitedMs: UInt64, updatedAt: Date) {
        self.session = session
        self.pid = pid
        self.waitedMs = waitedMs
        self.updatedAt = updatedAt
    }

    private struct Line: Decodable {
        var progress: String
        var session: String
        var pid: UInt64?
        var waitedMs: UInt64
        enum CodingKeys: String, CodingKey { case progress, session, pid, waitedMs = "waited_ms" }
    }

    /// The report a stdout line carries; nil for any other line (the ensure's reply).
    static func parse(_ line: String, at now: Date = Date()) -> RestoreProgressReport? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.contains("\"progress\""),
              let decoded = try? JSONDecoder().decode(Line.self, from: Data(trimmed.utf8)),
              decoded.progress == "restoring" else { return nil }
        return RestoreProgressReport(session: decoded.session, pid: decoded.pid.flatMap { Int32(exactly: $0) },
                                     waitedMs: decoded.waitedMs, updatedAt: now)
    }
}
