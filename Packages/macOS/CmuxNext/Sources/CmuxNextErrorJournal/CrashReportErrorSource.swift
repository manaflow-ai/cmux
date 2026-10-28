public import Foundation
import CmuxNextCompat

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
        let now = self.now()
        let latest = now.addingTimeInterval(Self.clockSlack)
        let since = cursor.flatMap { Self.cursorDate($0, now: now) } ?? now.addingTimeInterval(-firstLookBack)
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: directory.path)) ?? []
        var newest = since
        var events: [ErrorEvent] = []
        for name in names where name.hasSuffix(".ips") && prefixes.contains(where: { name.lowercased().hasPrefix($0) }) {
            let url = directory.appendingPathComponent(name)
            // Regular files only: opening a FIFO named like a report would wait for a writer forever.
            guard let attributes: [FileAttributeKey: Any] = try? FileManager.checked.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date, modified > since, modified <= latest else { continue }
            newest = max(newest, modified)
            events.append(Self.event(report: url, modified: modified))
        }
        // decode-trap-allow: newest is a date this harvest bounded: since (cursorDate's window, or now minus
        // firstLookBack) or a report dated after since and at most now plus clockSlack.
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
        let head = (try? FileHandle.blockingForReading(from: url)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.blockingRead(upToCount: 64 << 10)
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
        let exception = Self.first(#""exception"\s*:\s*\{[^}]*"type"\s*:\s*"([^"]+)""#, in: text)
        let signal = Self.first(#""signal"\s*:\s*"([^"]+)""#, in: text)
        let frame = Self.first(#""symbol"\s*:\s*"([^"]+)""#, in: text)
        let message = ["\(kind) \(app)", exception, signal].compactMap { $0 }.joined(separator: " ")
        var context = ["report": url.path]
        if let version = header["app_version"] as? String { context["version"] = version }
        return ErrorEvent(source: "crash", level: .crash, message: message, topFrame: frame, context: context,
                          date: modified)
    }

    private static func first(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return match.capture(1, in: text)
    }
}
