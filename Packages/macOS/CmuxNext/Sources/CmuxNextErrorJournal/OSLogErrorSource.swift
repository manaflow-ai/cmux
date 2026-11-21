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

    /// The longest time one read goes back: 3 days, the time that Copy Logs shows.
    public static let longestWindow: TimeInterval = 3 * 86_400
    /// A read that found nothing new ends this long before it was asked: an entry that the log
    /// store did not have yet at that moment is found by the next read. The 5 s is a margin, not a
    /// measured delay of the log store: an entry that the store shows later than that is not read.
    static let storeLag: TimeInterval = 5
    /// The most entries one read keeps: the newest ones of its window.
    static let mostEntries = 5000

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
        var start = launchDate
        if let cursor {
            let parts = cursor.split(separator: ":")
            if parts.count == 2, Int32(parts[0]) == processID, let ms = Double(parts[1]) {
                start = Date(timeIntervalSince1970: ms / 1000)
            }
        }
        start = max(start, asked.addingTimeInterval(-Self.longestWindow))
        // logd filters: entries below error are never decoded here. Reading every level cost the
        // app 2.6 to 4.4 mW in the windows a harvest fell in, with 20 hidden Chromium tabs (msg 2654).
        let entries = try reader.entries(since: start, matching: Self.errorsAndFaults)
        // A window can hold more than one read keeps (an app at rest for a night while one error
        // repeats; nothing reads at rest). Keep the newest, as LogFileErrorSource does, and do not
        // come back for the older ones: the log store gives its entries oldest first.
        let found = entries.filter { $0.date > start && ($0.level == .error || $0.level == .fault) }
        var events: [ErrorEvent] = []
        var newest = start
        for entry in found.suffix(Self.mostEntries) {
            newest = max(newest, entry.date)
            events.append(Self.event(subsystem: entry.subsystem, category: entry.category,
                                     isFault: entry.level == .fault, message: entry.message, date: entry.date))
        }
        // The next read starts where this one ended: a read that found nothing does not leave its
        // window to the next one.
        let end = max(newest, asked.addingTimeInterval(-Self.storeLag))
        let ms = Int64((end.timeIntervalSince1970 * 1000).rounded(.up))
        return ErrorHarvest(events: events, cursor: "\(processID):\(ms)")
    }

    /// The log store predicate for errors and faults (`messageType`, as `log show --predicate` takes it).
    static var errorsAndFaults: NSPredicate { NSPredicate(format: "messageType == 'error' OR messageType == 'fault'") }

    /// Maps one log entry to an event: the first line is the message, a following `at …`
    /// line is the top frame.
    static func event(subsystem: String, category: String, isFault: Bool, message: String, date: Date) -> ErrorEvent {
        let source: String = if subsystem == ConsoleErrorCapture.subsystem {
            "page:\(category)"
        } else if subsystem.hasPrefix("com.cmuxterm") || subsystem.isEmpty {
            "app"
        } else {
            "system:\(subsystem)"
        }
        let lines = message.split(separator: "\n", omittingEmptySubsequences: true)
        let first = lines.first.map(String.init) ?? message
        let frame = lines.dropFirst().first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("at ") }
            .map { String($0.trimmingCharacters(in: .whitespaces).dropFirst(3)) }
        var level: ErrorLevel = isFault ? .fault : .error
        if source.hasPrefix("page:"), first.hasPrefix("[warn] ") { level = .warning }
        return ErrorEvent(source: source, level: level, message: first, topFrame: frame,
                          context: ["subsystem": subsystem, "category": category], date: date)
    }
}
