import CmuxNextCompat
public import Foundation

/// The hang report files in one folder (the app's `Application Support/<build>/HangReports`):
/// the watchdog aggregate, the main-thread part and the black box saved for the next launch, the outbox of reports
/// not yet accepted, the copy of the last report sent (View Hang Report), and the send log the daily
/// cap reads.
///
/// Its methods read and write files, so the actor runs on a serial utility queue of its own, never
/// on a cooperative pool thread. Tests pass a temporary folder.
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
    /// The actor's executor: its file work blocks this queue, not the pool.
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.app.next.hang-reports.store", qos: .utility)

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Makes the value from its parts.
    public init(directory: URL) {
        self.directory = directory
    }

    /// The readable copy of the last report sent.
    public nonisolated var lastReportURL: URL { directory.appending(path: "last-report.json") }
    /// The readable preview made when nothing was sent yet.
    public nonisolated var previewURL: URL { directory.appending(path: "preview-report.json") }
    private var pendingURL: URL { directory.appending(path: "pending.json") }
    /// The main-thread part (``MainThreadReportLedger/Saved``) a quit saved for the next launch.
    public nonisolated var pendingMainThreadURL: URL { directory.appending(path: "pending-main-thread.json") }
    /// The main-thread blocking site counts (``BlockingSiteLedger/Saved``) a quit saved for the next launch.
    public nonisolated var pendingBlockingSitesURL: URL { directory.appending(path: "pending-blocking-sites.json") }
    /// The black box a quit saved (``HangReportSavedBlackBox``).
    nonisolated var pendingBlackBoxURL: URL { directory.appending(path: "pending-blackbox.json") }
    private var sendLogURL: URL { directory.appending(path: "send-log.json") }
    private var outboxURL: URL { directory.appending(path: "outbox", directoryHint: .isDirectory) }

    // MARK: Watchdog aggregate

    /// Saves the watchdog aggregate for the next launch (an empty one removes the file).
    public func savePending(_ aggregate: StallAggregate) {
        guard !aggregate.isEmpty else { return removePending() }
        write(try? JSONEncoder().encode(aggregate), to: pendingURL)
    }

    /// The saved aggregate, removed from disk (it joins the collector's).
    public func takePending() -> StallAggregate? { take(StallAggregate.self, from: pendingURL) }

    private func removePending() { try? FileManager.checked.removeItem(at: pendingURL) }

    /// The main-thread part a quit saved, removed from disk (it joins the ledger's).
    public func takePendingMainThread() -> MainThreadReportLedger.Saved? {
        take(MainThreadReportLedger.Saved.self, from: pendingMainThreadURL)
    }

    /// The blocking site counts a quit saved, removed from disk (they join the ledger's).
    public func takePendingBlockingSites() -> BlockingSiteLedger.Saved? {
        take(BlockingSiteLedger.Saved.self, from: pendingBlockingSitesURL)
    }

    /// The black box a quit saved, removed from disk (the collector holds it for the next report).
    func takePendingBlackBox() -> HangReportSavedBlackBox? {
        take(HangReportSavedBlackBox.self, from: pendingBlackBoxURL)
    }

    /// The value saved at `url`, removed from disk; nil when missing or unreadable.
    private func take<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        defer { try? FileManager.checked.removeItem(at: url) }
        guard let data = try? Data(blockingContentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    // MARK: Outbox

    /// Queues a report body; the oldest go when more than ``outboxLimit`` wait.
    public func enqueue(_ body: Data, reportId: String) {
        try? FileManager.checked.createDirectory(at: outboxURL, withIntermediateDirectories: true)
        write(body, to: outboxURL.appending(path: "\(reportId).json"))
        let entries = outbox(now: Date())
        for entry in entries.dropLast(Self.outboxLimit) { try? FileManager.checked.removeItem(at: entry.url) }
    }

    /// The waiting reports, oldest first; older than ``outboxMaxAge`` are deleted.
    public func outbox(now: Date) -> [(url: URL, body: Data)] {
        let files = (try? FileManager.checked.contentsOfDirectory(at: outboxURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Date)? in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > Self.outboxMaxAge {
                try? FileManager.checked.removeItem(at: url)
                return nil
            }
            return (url, date)
        }
        return dated.sorted { $0.1 < $1.1 }.compactMap { entry -> (url: URL, body: Data)? in
            (try? Data(contentsOf: entry.0)).map { (url: entry.0, body: $0) }
        }
    }

    /// Deletes one outbox entry.
    public func remove(_ url: URL) { try? FileManager.checked.removeItem(at: url) }

    // MARK: Last report and send log

    /// Keeps the readable copy of a report that was sent.
    public func saveLastReport(_ readable: Data) {
        write(readable, to: lastReportURL)
        try? FileManager.checked.removeItem(at: previewURL)
    }

    /// Keeps the readable preview View Hang Report opens.
    public func savePreview(_ readable: Data) { write(readable, to: previewURL) }

    /// Whether a report was ever sent from this Mac.
    public func hasLastReport() -> Bool { FileManager.checked.fileExists(atPath: lastReportURL.path) }

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
        try? FileManager.checked.removeItem(at: pendingMainThreadURL)
        try? FileManager.checked.removeItem(at: pendingBlockingSitesURL)
        try? FileManager.checked.removeItem(at: pendingBlackBoxURL)
        try? FileManager.checked.removeItem(at: outboxURL)
        try? FileManager.checked.removeItem(at: previewURL)
    }

    private func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        try? FileManager.checked.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
