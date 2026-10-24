public import Foundation

/// This process's own unified-log errors and faults (`Logger.error`, `Logger.fault`). Reads
/// `OSLogStore` scoped to the current process, after the last harvested entry of this launch; the
/// store returns only errors and faults (``errorsAndFaults``), so other entries are never decoded
/// in this process. The subsystems whose errors are recorded when they happen are left out
/// (``ErrorReporter/recordedSubsystems``: cmux's reported errors and the page consoles), since
/// the reporter logs them for Console.app only.
///
/// The log store of a process that ended cannot be read (only the current process's is), so what
/// this source finds is best effort: frameworks logging in-process (WebKit, AppKit), and cmux
/// sites that still log through `Logger` instead of an ``ErrorReporter``. The app harvests it at
/// launch, at quit and on `errors.list`.
///
/// A read's cost grows with the log after the cursor (about 1.4 s for 300 s of a busy run), so
/// it never decides how long a caller waits: it reads entry by entry, stops when its task is
/// cancelled (the quit once the engines stopped, `errors.list` at its deadline) and returns what
/// it read with the cursor at the last entry, and it hands back at most ``batchLimit`` events per
/// read with ``ErrorHarvest/more`` set, so the journal reads the rest from there.
///
/// Sources: `page:<page>` for the page console subsystem (the capture's events), `app` for
/// `com.cmuxterm` subsystems, `system:<subsystem>` for frameworks logging in-process (WebKit, AppKit).
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

    /// Most events one read hands back; the journal reads the rest from the cursor (bounds the
    /// memory of one read, not what a harvest takes).
    static let batchLimit = 5000

    public func collect(after cursor: String?) async throws -> ErrorHarvest {
        var start = launchDate
        if let cursor {
            let parts = cursor.split(separator: ":")
            if parts.count == 2, Int32(parts[0]) == processID, let ms = Double(parts[1]) {
                start = Date(timeIntervalSince1970: ms / 1000)
            }
        }
        var events: [ErrorEvent] = []
        var newestMs = Self.cursorMs(start)
        var more = false
        // logd filters: entries below error are never decoded here. Reading every level cost the
        // app 2.6 to 4.4 mW in the windows a harvest fell in, with 20 hidden Chromium tabs (msg 2654).
        try reader.read(since: start, matching: Self.errorsAndFaults) { entry in
            // Cancelled (the quit's engines stopped, errors.list's deadline): keep what was read.
            guard !Task.isCancelled else { return false }
            guard entry.date > start else { return true }
            let ms = Self.cursorMs(entry.date)
            // At the bound, stop only between milliseconds: the cursor is a rounded-up ms, so an
            // entry in the same ms as the last one kept would be skipped by the next read.
            if events.count >= Self.batchLimit, ms > newestMs {
                more = true
                return false
            }
            newestMs = max(newestMs, ms)
            guard entry.level == .error || entry.level == .fault, !ErrorReporter.recordedSubsystems.contains(entry.subsystem) else { return true }
            events.append(Self.event(subsystem: entry.subsystem, category: entry.category,
                                     isFault: entry.level == .fault, message: entry.message, date: entry.date))
            return true
        }
        return ErrorHarvest(events: events, cursor: "\(processID):\(newestMs)", more: more)
    }

    /// `date` as the cursor's unix ms, rounded up: the next read starts after every entry up to it.
    private static func cursorMs(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.up))
    }

    /// The log store predicate for errors and faults (`messageType`, as `log show --predicate` takes
    /// it), without the subsystems a reporter already recorded.
    static var errorsAndFaults: NSPredicate {
        // One `!=` per subsystem: the log store's predicate support is narrower than NSPredicate's.
        let kept = ErrorReporter.recordedSubsystems.sorted().map { NSPredicate(format: "subsystem != %@", $0) }
        return NSCompoundPredicate(andPredicateWithSubpredicates:
            [NSPredicate(format: "messageType == 'error' OR messageType == 'fault'")] + kept)
    }

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
