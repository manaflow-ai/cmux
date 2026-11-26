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
        let names = (try? files.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let wanted = ErrorJournalFFI.object("error_journal_crash_names", ["names": names, "prefixes": prefixes])?["names"]
            as? [String] else { throw ErrorJournalFFI.Unanswered(operation: "error_journal_crash_names") }
        let stamped: [[String: Any]] = wanted.map { name in
            let url = directory.appendingPathComponent(name)
            var file: [String: Any] = ["name": name]
            if let modified = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date {
                file["modified"] = modified.timeIntervalSince1970
            }
            return file
        }
        var request: [String: Any] = ["now": Date().timeIntervalSince1970, "look_back": firstLookBack, "files": stamped]
        if let cursor { request["cursor"] = cursor }
        guard let scan = ErrorJournalFFI.decode(Scan.self, "error_journal_crash_scan", request) else {
            throw ErrorJournalFFI.Unanswered(operation: "error_journal_crash_scan")
        }
        let events = scan.reports.map { report in
            Self.event(report: directory.appendingPathComponent(report.name),
                       modified: Date(timeIntervalSince1970: report.modified ?? 0))
        }
        return ErrorHarvest(events: events, cursor: scan.cursor)
    }

    /// The report's event (Rust reads its kind, app, exception and frame from the first 64 KiB).
    static func event(report url: URL, modified: Date) -> ErrorEvent {
        let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 64 << 10)
        } ?? Data()
        let request: [String: Any] = ["text": String(decoding: head, as: UTF8.self), "path": url.path,
                                      "modified": modified.timeIntervalSince1970]
        return ErrorJournalFFI.decode(EventReply.self, "error_journal_crash_event", request)?.event.event
            ?? ErrorEvent(source: "crash", level: .crash, message: "report \(url.deletingPathExtension().lastPathComponent)",
                          context: ["report": url.path], date: modified)
    }

    private struct Scan: Decodable {
        struct Report: Decodable {
            let name: String
            let modified: Double?
        }

        let reports: [Report]
        let cursor: String
    }

    private struct EventReply: Decodable {
        let event: ErrorJournalFFI.WireEvent
    }
}
