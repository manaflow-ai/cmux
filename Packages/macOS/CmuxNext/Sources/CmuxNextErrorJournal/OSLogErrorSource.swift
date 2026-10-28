public import Foundation

/// This process's own unified-log errors and faults (`Logger.error`, `Logger.fault`, and the
/// page console errors ``ConsoleErrorCapture`` logs). Reads `OSLogStore` scoped to the current
/// process, after the last harvested entry of this launch; the store returns only errors and
/// faults (``errorsAndFaults``), so other entries are never decoded in this process.
///
/// Sources: `page:<page>` for the page console subsystem, `app` for `com.cmuxterm` subsystems,
/// `system:<subsystem>` for frameworks logging in-process (WebKit, AppKit).
public struct OSLogErrorSource: ErrorHarvestSource {
    public let id: String
    private let processID: Int32
    private let launchDate: Date
    private let reader: any OSLogReading

    /// Makes the source for this process.
    /// - Parameters:
    ///   - id: Cursor key.
    ///   - processID: Ties the cursor to this launch.
    ///   - launchDate: Where the first harvest of this launch starts.
    public init(id: String = "oslog", processID: Int32 = ProcessInfo.processInfo.processIdentifier,
                launchDate: Date = Date()) {
        self.init(id: id, processID: processID, launchDate: launchDate, reader: OSLogStoreReader())
    }

    /// Makes the source on `reader` (tests pass a fake log store).
    init(id: String = "oslog", processID: Int32, launchDate: Date, reader: any OSLogReading) {
        self.id = id
        self.processID = processID
        self.launchDate = launchDate
        self.reader = reader
    }

    public func collect(after cursor: String?) async throws -> ErrorHarvest {
        var start = launchDate
        if let cursor {
            let parts = cursor.split(separator: ":")
            if parts.count == 2, Int32(parts[0]) == processID, let ms = Double(parts[1]) {
                start = Date(timeIntervalSince1970: ms / 1000)
            }
        }
        // logd filters: entries below error are never decoded here. Reading every level cost the
        // app 2.6 to 4.4 mW in the windows a harvest fell in, with 20 hidden Chromium tabs (msg 2654).
        let entries = try reader.entries(since: start, matching: Self.errorsAndFaults)
        var events: [ErrorEvent] = []
        var newest = start
        for entry in entries where entry.date > start {
            guard entry.level == .error || entry.level == .fault else { continue }
            newest = max(newest, entry.date)
            events.append(Self.event(subsystem: entry.subsystem, category: entry.category,
                                     isFault: entry.level == .fault, message: entry.message, date: entry.date))
            if events.count >= 5000 { break }
        }
        let ms = Int64((newest.timeIntervalSince1970 * 1000).rounded(.up))
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
