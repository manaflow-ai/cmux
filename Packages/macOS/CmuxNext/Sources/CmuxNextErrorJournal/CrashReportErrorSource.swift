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

    /// Makes the source.
    public init(id: String = "crash-reports",
                directory: URL = FileManager().homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                prefixes: [String] = ["cmux", "acpmux", "optchat", "cmux-tui"], firstLookBack: TimeInterval = 7 * 86400) {
        self.id = id
        self.directory = directory
        self.prefixes = prefixes.map { $0.lowercased() }
        self.firstLookBack = firstLookBack
    }

    public func collect(after cursor: String?) async throws -> ErrorHarvest {
        let files = FileManager()
        let since = cursor.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? Date().addingTimeInterval(-firstLookBack)
        let names = (try? files.contentsOfDirectory(atPath: directory.path)) ?? []
        var newest = since
        var events: [ErrorEvent] = []
        for name in names where name.hasSuffix(".ips") && prefixes.contains(where: { name.lowercased().hasPrefix($0) }) {
            let url = directory.appendingPathComponent(name)
            guard let modified = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified > since else { continue }
            newest = max(newest, modified)
            events.append(Self.event(report: url, modified: modified))
        }
        let ms = Int64((newest.timeIntervalSince1970 * 1000).rounded(.up))
        return ErrorHarvest(events: events, cursor: String(ms))
    }

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
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
