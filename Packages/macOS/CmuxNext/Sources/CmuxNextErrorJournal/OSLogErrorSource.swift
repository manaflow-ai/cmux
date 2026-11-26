public import Foundation

/// This process's own unified-log errors and faults (`Logger.error`, `Logger.fault`, and the
/// page console errors ``ConsoleErrorCapture`` logs). Reads `OSLogStore` scoped to the current
/// process; the store returns only errors and faults (``errorsAndFaults``), so other entries are
/// never decoded in this process.
///
/// One read costs seconds of CPU in the log service whatever its window (2.0 s wall for 5 s and
/// for 24 h on a Mac with a 2.1 GB log store), so only a demand reads (``ErrorJournal/harvest(_:)``).
/// A read starts where the last one of this launch ended, also when that one found nothing, and
/// never further back than ``longestWindow``.
///
/// Sources: `page:<page>` for the page console subsystem, `app` for `com.cmuxterm` subsystems,
/// `system:<subsystem>` for frameworks logging in-process (WebKit, AppKit).
public struct OSLogErrorSource: ErrorHarvestSource {
    public let id: String
    private let processID: Int32
    private let launchDate: Date
    private let reader: any OSLogReading
    private let now: @Sendable () -> Date

    /// The longest time one read goes back: 3 days, the time that Copy Logs shows (Rust's window).
    public static let longestWindow: TimeInterval = 3 * 86_400

    /// Makes the source for this process.
    /// - Parameters:
    ///   - id: Cursor key.
    ///   - processID: Ties the cursor to this launch.
    ///   - launchDate: Where the first read of this launch starts.
    public init(id: String = "oslog", processID: Int32 = ProcessInfo.processInfo.processIdentifier,
                launchDate: Date = Date()) {
        self.init(id: id, processID: processID, launchDate: launchDate, reader: OSLogStoreReader())
    }

    /// Makes the source on `reader` (tests pass a fake log store and their own time).
    init(id: String = "oslog", processID: Int32, launchDate: Date, reader: any OSLogReading,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.id = id
        self.processID = processID
        self.launchDate = launchDate
        self.reader = reader
        self.now = now
    }

    public func collect(after cursor: String?) async throws -> ErrorHarvest {
        let asked = now()
        var request: [String: Any] = ["process_id": processID, "launch": launchDate.timeIntervalSince1970,
                                      "now": asked.timeIntervalSince1970]
        if let cursor { request["cursor"] = cursor }
        guard let start = ErrorJournalFFI.object("error_journal_oslog_start", request)?["start"] as? Double else {
            throw ErrorJournalFFI.Unanswered(operation: "error_journal_oslog_start")
        }
        // logd filters: entries below error are never decoded here. Reading every level cost the
        // app 2.6 to 4.4 mW in the windows a harvest fell in, with 20 hidden Chromium tabs (msg 2654).
        let entries = try reader.entries(since: Date(timeIntervalSince1970: start), matching: Self.errorsAndFaults)
        // Rust keeps the newest of the window (a read keeps at most 5000) and moves the cursor to
        // where this read ended, also when it found nothing.
        return try ErrorJournalFFI.harvest("error_journal_oslog_collect", [
            "start": start, "now": asked.timeIntervalSince1970, "process_id": processID,
            "records": entries.map(Self.json),
        ])
    }

    /// The log store predicate for errors and faults (`messageType`, as `log show --predicate` takes it).
    static var errorsAndFaults: NSPredicate { NSPredicate(format: "messageType == 'error' OR messageType == 'fault'") }

    private static func json(_ record: OSLogRecord) -> [String: Any] {
        ["subsystem": record.subsystem, "category": record.category, "level": record.level.messageType,
         "message": record.message, "date": record.date.timeIntervalSince1970]
    }

    /// Maps one log entry to an event: the first line is the message, a following `at …`
    /// line is the top frame.
    static func event(subsystem: String, category: String, isFault: Bool, message: String, date: Date) -> ErrorEvent {
        let record = OSLogRecord(date: date, level: isFault ? .fault : .error, subsystem: subsystem,
                                 category: category, message: message)
        let request: [String: Any] = ["start": date.timeIntervalSince1970 - 1, "now": date.timeIntervalSince1970,
                                      "process_id": 0, "records": [json(record)]]
        return (try? ErrorJournalFFI.harvest("error_journal_oslog_collect", request))?.events.first
            ?? ErrorEvent(source: "app", level: isFault ? .fault : .error, message: message,
                          context: ["subsystem": subsystem, "category": category], date: date)
    }
}
