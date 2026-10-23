public import Foundation

/// The hang report files in one folder (the app's `Application Support/<build>/HangReports`):
/// the watchdog aggregate saved for the next launch, the outbox of reports not yet accepted, the
/// copy of the last report sent (View Hang Report), and the send log the daily cap reads.
///
/// Tests pass a temporary folder.
public actor HangReportStore {
    /// When reports were sent, for the daily cap and the 24-hour watchdog report.
    public struct SendLog: Codable, Sendable, Equatable {
        /// When the last report was queued.
        public var lastSentAt: Date?
        /// The UTC day (`yyyy-MM-dd`).
        public var day: String = ""
        /// Reports queued on ``day``.
        public var sentToday: Int = 0

        /// Makes the value from its parts.
        public init() {}
    }

    /// The most reports the outbox keeps.
    public static let outboxLimit = 3
    /// How long an unsent report is kept.
    public static let outboxMaxAge: TimeInterval = 14 * 24 * 60 * 60

    /// The folder that holds every hang report file.
    public nonisolated let directory: URL
    private let manager = FileManager.default

    /// Makes the value from its parts.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The readable copy of the last report sent.
    public nonisolated var lastReportURL: URL { directory.appending(path: "last-report.json") }
    /// The readable preview made when nothing was sent yet.
    public nonisolated var previewURL: URL { directory.appending(path: "preview-report.json") }
    private var pendingURL: URL { directory.appending(path: "pending.json") }
    private var sendLogURL: URL { directory.appending(path: "send-log.json") }
    private var outboxURL: URL { directory.appending(path: "outbox", directoryHint: .isDirectory) }

    // MARK: Watchdog aggregate

    /// Saves the watchdog aggregate for the next launch (an empty one removes the file).
    public func savePending(_ aggregate: StallAggregate) {
        guard !aggregate.isEmpty else { return removePending() }
        write(try? JSONEncoder().encode(aggregate), to: pendingURL)
    }

    /// The saved aggregate, removed from disk (it joins the collector's).
    public func takePending() -> StallAggregate? {
        defer { removePending() }
        guard let data = try? Data(contentsOf: pendingURL) else { return nil }
        return try? JSONDecoder().decode(StallAggregate.self, from: data)
    }

    private func removePending() { try? manager.removeItem(at: pendingURL) }

    // MARK: Outbox

    /// Queues a report body; the oldest go when more than ``outboxLimit`` wait.
    public func enqueue(_ body: Data, reportId: String) {
        try? manager.createDirectory(at: outboxURL, withIntermediateDirectories: true)
        write(body, to: outboxURL.appending(path: "\(reportId).json"))
        let entries = outbox(now: Date())
        for entry in entries.dropLast(Self.outboxLimit) { try? manager.removeItem(at: entry.url) }
    }

    /// The waiting reports, oldest first; older than ``outboxMaxAge`` are deleted.
    public func outbox(now: Date) -> [(url: URL, body: Data)] {
        let files = (try? manager.contentsOfDirectory(at: outboxURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Date)? in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > Self.outboxMaxAge {
                try? manager.removeItem(at: url)
                return nil
            }
            return (url, date)
        }
        return dated.sorted { $0.1 < $1.1 }.compactMap { entry -> (url: URL, body: Data)? in
            (try? Data(contentsOf: entry.0)).map { (url: entry.0, body: $0) }
        }
    }

    /// Deletes one outbox entry.
    public func remove(_ url: URL) { try? manager.removeItem(at: url) }

    // MARK: Last report and send log

    /// Keeps the readable copy of a report that was sent.
    public func saveLastReport(_ readable: Data) {
        write(readable, to: lastReportURL)
        try? manager.removeItem(at: previewURL)
    }

    /// Keeps the readable preview View Hang Report opens.
    public func savePreview(_ readable: Data) { write(readable, to: previewURL) }

    /// Whether a report was ever sent from this Mac.
    public func hasLastReport() -> Bool { manager.fileExists(atPath: lastReportURL.path) }

    /// The send log (empty when missing).
    public func sendLog() -> SendLog {
        guard let data = try? Data(contentsOf: sendLogURL), let log = try? JSONDecoder().decode(SendLog.self, from: data) else {
            return SendLog()
        }
        return log
    }

    /// Saves the send log.
    public func saveSendLog(_ log: SendLog) { write(try? JSONEncoder().encode(log), to: sendLogURL) }

    /// Deletes everything but the last report's copy (hang reports turned off).
    public func clearQueued() {
        removePending()
        try? manager.removeItem(at: outboxURL)
        try? manager.removeItem(at: previewURL)
    }

    private func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
