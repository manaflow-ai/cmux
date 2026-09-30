import Foundation
import os

/// A captured focus/keyboard desync (plans/cmux-next/input-spec.md
/// section 4): the invariants that broke, the observation that showed it,
/// and the journal that led there. Written as JSON so it can be attached to
/// a bug and replayed (`debug.replay`, `scripts/cmux-next/input-replay.py`).
nonisolated struct DesyncReport: Hashable, Sendable, Codable {
    var id: String
    var sequence: Int
    var createdAt: Date
    var uptimeNanos: UInt64
    var tag: String?
    var violations: [InputViolation]
    var observation: InputObservation
    var journal: [InputJournalEntry]
    var journalStats: InputJournal.Stats

    /// One line per violation, for logs and `debug.desync`.
    var summary: [String] { violations.map { "\($0.invariant.rawValue) \($0.window ?? "-"): \($0.detail)" } }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Where desync reports go: `~/Library/Logs/cmux-next/<tag>/desync/`
/// (`release` for untagged builds). Writes happen off the main actor.
nonisolated struct DesyncReportStore: Sendable {
    /// Reports kept on disk per build; older ones are deleted.
    static let keep = 50

    let directory: URL?

    init(tag: String?, logs: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first) {
        directory = logs?.appending(path: "Logs/cmux-next/\(tag ?? "release")/desync", directoryHint: .isDirectory)
    }

    func url(for report: DesyncReport) -> URL? {
        directory?.appending(path: "\(report.id).json")
    }

    /// Writes `data` for `report` and prunes old reports, off the main actor.
    func write(_ data: Data, for report: DesyncReport) {
        guard let directory, let url = url(for: report) else { return }
        Task.detached(priority: .utility) {
            let files = FileManager.default
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                let existing = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for old in existing.dropLast(Self.keep) { try? files.removeItem(at: old) }
            } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "app.input")
                    .error("desync report write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
