public import Foundation

/// New system crash and hang reports (`.ips`) of cmux processes in
/// `~/Library/Logs/DiagnosticReports`. Each becomes one `crash` event naming the process,
/// the report kind and the exception; the report's path goes in the context.
public struct CrashReportErrorSource: ErrorHarvestSource {
    public let id: String
    /// The reports folder.
    public let directory: URL
    /// Report file names must start with one of these (case-insensitive).
    public let prefixes: [String]
    /// The first harvest looks back this far.
    public let firstLookBack: TimeInterval
    private let now: @Sendable () -> Date

    /// Makes the source.
    /// - Parameter now: The current date; tests pass a fixed one.
    public init(id: String = "crash-reports",
                directory: URL = FileManager().homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                prefixes: [String] = ["cmux", "acpmux", "optchat", "cmux-tui"], firstLookBack: TimeInterval = 7 * 86400,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.id = id
        self.directory = directory
        self.prefixes = prefixes.map { $0.lowercased() }
        self.firstLookBack = firstLookBack
        self.now = now
    }

    public func collect(after cursor: String?) async throws -> ErrorHarvest {
        harvest(after: cursor)
    }

    /// ``collect(after:)`` as a plain call, for the synchronous fuzz entry (p10-stability-029).
    /// Reports dated after now (plus ``clockSlack``) wait for their date, so the cursor it
    /// returns is always one ``cursorDate(_:now:)`` accepts on the next harvest.
    func harvest(after cursor: String?) -> ErrorHarvest {
        let files = FileManager()
        let now = self.now()
        let latest = now.addingTimeInterval(Self.clockSlack)
        let since = cursor.flatMap { Self.cursorDate($0, now: now) } ?? now.addingTimeInterval(-firstLookBack)
        let names = (try? files.contentsOfDirectory(atPath: directory.path)) ?? []
        var newest = since
        var events: [ErrorEvent] = []
        for name in names where name.hasSuffix(".ips") && prefixes.contains(where: { name.lowercased().hasPrefix($0) }) {
            let url = directory.appendingPathComponent(name)
            // Regular files only: opening a FIFO named like a report would wait for a writer forever.
            guard let attributes = try? files.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date, modified > since, modified <= latest else { continue }
            newest = max(newest, modified)
            events.append(Self.event(report: url, modified: modified))
        }
        let ms = Int64((newest.timeIntervalSince1970 * 1000).rounded(.up))
        return ErrorHarvest(events: events, cursor: String(ms))
    }

    /// The date a saved cursor (milliseconds since 1970) names, or nil (the harvest starts over
    /// with ``firstLookBack``) when it is no finite number or falls outside the last
    /// ``maxCursorAge`` up to ``clockSlack`` after `now`: a damaged `cursors.json`, or one saved
    /// while the clock was set ahead, which would hide every report until that date.
    static func cursorDate(_ cursor: String, now: Date) -> Date? {
        guard let ms = Double(cursor), ms.isFinite else { return nil }
        let date = Date(timeIntervalSince1970: ms / 1000)
        guard date >= now.addingTimeInterval(-maxCursorAge), date <= now.addingTimeInterval(clockSlack) else { return nil }
        return date
    }

    /// How far a cursor may run ahead of the clock: the cursor rounds up to the millisecond
    /// and a time sync can set the clock back a little.
    static let clockSlack: TimeInterval = 60

    /// The oldest cursor a harvest resumes from (one year).
    static let maxCursorAge: TimeInterval = 365 * 86400

    static func event(report url: URL, modified: Date) -> ErrorEvent {
        let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 64 << 10)
        } ?? Data()
        let text = String(decoding: head, as: UTF8.self)
        let header = text.split(separator: "\n", maxSplits: 1).first.flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        } ?? [:]
        let app = header["app_name"] as? String ?? url.deletingPathExtension().lastPathComponent
        let kind: String = switch header["bug_type"] as? String {
        case "309": "crash"
        case "298", "288": "hang"
        case "211": "analytics"
        case let other?: "report \(other)"
        case nil: "report"
        }
        let exception = Self.exceptionType(in: text)
        let signal = Self.first(#""signal"\s*:\s*"([^"]+)""#, in: text)
        let frame = Self.first(#""symbol"\s*:\s*"([^"]+)""#, in: text)
        let message = ["\(kind) \(app)", exception, signal].compactMap { $0 }.joined(separator: " ")
        var context = ["report": url.path]
        if let version = header["app_version"] as? String { context["version"] = version }
        return ErrorEvent(source: "crash", level: .crash, message: message, topFrame: frame, context: context,
                          date: modified)
    }

    /// The `type` in the report's first `"exception" : {…}` object that names one before its first
    /// `}` (the last one there, as `"exception"\s*:\s*\{[^}]*"type"\s*:\s*"([^"]+)"` finds it).
    ///
    /// One pass (p10-stability-191): as one regex, every `"exception"` scanned to its `}` and back,
    /// quadratic when a damaged report repeats the key with no `}`. An `"exception"` inside an object
    /// that named no type opens a part of that object, so the next search starts after its `}`.
    static func exceptionType(in text: String) -> String? {
        guard let opening = try? NSRegularExpression(pattern: #""exception"\s*+:\s*+\{"#),
              let value = try? NSRegularExpression(pattern: #"\s*+:\s*+"([^"]++)""#) else { return nil }
        let source = text as NSString
        var from = 0
        while from < source.length,
              let object = opening.firstMatch(in: text, range: NSRange(location: from, length: source.length - from)) {
            let bodyStart = NSMaxRange(object.range)
            let close = source.range(of: "}", options: .literal,
                                     range: NSRange(location: bodyStart, length: source.length - bodyStart))
            let bodyEnd = close.location == NSNotFound ? source.length : close.location
            var searchEnd = bodyEnd
            while searchEnd > bodyStart {
                let key = source.range(of: #""type""#, options: [.literal, .backwards],
                                       range: NSRange(location: bodyStart, length: searchEnd - bodyStart))
                guard key.location != NSNotFound else { break }
                let after = NSMaxRange(key)
                if let match = value.firstMatch(in: text, options: .anchored,
                                                range: NSRange(location: after, length: source.length - after)),
                   let range = Range(match.range(at: 1), in: text) {
                    return String(text[range])
                }
                searchEnd = NSMaxRange(key) - 1 // a "type" that overlaps this one starts before it
            }
            from = bodyEnd
        }
        return nil
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
