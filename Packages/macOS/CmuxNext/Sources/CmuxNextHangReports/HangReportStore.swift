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

        /// The log after taking one of today's sends at `now`; nil when today's are used up (or
        /// the rules do not answer: nothing is sent). The cap is Rust's.
        static func slot(after log: SendLog, now: Date) -> SendLog? {
            struct Wire: Codable {
                var lastSentAt: Double?
                var day: String
                var sentToday: Int
            }
            struct Request: Encodable {
                var log: Wire
                var now: Double
            }
            struct Reply: Decodable {
                var log: Wire?
            }
            let request = Request(log: Wire(lastSentAt: log.lastSentAt?.timeIntervalSince1970, day: log.day, sentToday: log.sentToday),
                                  now: now.timeIntervalSince1970)
            guard let wire = HangReportRules.call("send_slot", request, as: Reply.self)?.log else { return nil }
            var next = SendLog()
            next.lastSentAt = wire.lastSentAt.map(Date.init(timeIntervalSince1970:))
            next.day = wire.day
            next.sentToday = wire.sentToday
            return next
        }
    }

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

    /// Queues a report body; the oldest go when more wait than the outbox keeps.
    public func enqueue(_ body: Data, reportId: String) {
        try? manager.createDirectory(at: outboxURL, withIntermediateDirectories: true)
        write(body, to: outboxURL.appending(path: "\(reportId).json"))
        for name in plan(now: Date())?.trim ?? [] { try? manager.removeItem(at: outboxURL.appending(path: name)) }
    }

    /// The waiting reports, oldest first; expired ones are deleted (none when the rules do not answer).
    public func outbox(now: Date) -> [(url: URL, body: Data)] {
        (plan(now: now)?.ordered ?? []).compactMap { name -> (url: URL, body: Data)? in
            let url = outboxURL.appending(path: name)
            return (try? Data(contentsOf: url)).map { (url: url, body: $0) }
        }
    }

    private struct Plan: Decodable {
        var expired: [String]
        var ordered: [String]
        var trim: [String]
    }

    /// The outbox files by name and age, planned by Rust; the expired ones are deleted here.
    private func plan(now: Date) -> Plan? {
        struct Entry: Encodable {
            var name: String
            var modified: Double?
        }
        struct Request: Encodable {
            var entries: [Entry]
            var now: Double
        }
        let files = (try? manager.contentsOfDirectory(at: outboxURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let entries = files.map { url in
            Entry(name: url.lastPathComponent,
                  modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970)
        }
        guard let plan = HangReportRules.call("outbox_plan", Request(entries: entries, now: now.timeIntervalSince1970), as: Plan.self) else {
            return nil
        }
        for name in plan.expired { try? manager.removeItem(at: outboxURL.appending(path: name)) }
        return plan
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
