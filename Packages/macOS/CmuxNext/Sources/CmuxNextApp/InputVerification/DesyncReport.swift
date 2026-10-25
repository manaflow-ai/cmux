import Foundation
import os
import CmuxNextCompat
import CmuxNextWakeups

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
/// (`release` for untagged builds). Writes run on the BackgroundWork files lane, never on the main actor
/// or the cooperative pool.
nonisolated struct DesyncReportStore: Sendable {
    /// Reports kept on disk per build; older ones are deleted.
    static let keep = 50

    let directory: URL?
    /// The blocking-work lanes the reports are written on.
    let work: BackgroundWork

    /// - Parameter work: the app's blocking-work lanes (`AppServices.work`); tests get lanes of their own.
    init(tag: String?, logs: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first,
         work: BackgroundWork = BackgroundWork(label: "com.cmuxterm.next.work.desync")) {
        directory = logs?.appending(path: "Logs/cmux-next/\(tag ?? "release")/desync", directoryHint: .isDirectory)
        self.work = work
    }

    func url(for report: DesyncReport) -> URL? {
        directory?.appending(path: "\(report.id).json")
    }

    /// Writes `data` for `report` and prunes old reports, on the files lane at best effort (nobody waits).
    func write(_ data: Data, for report: DesyncReport) {
        guard let directory, let url = url(for: report) else { return }
        work.post(.bestEffort, mayBlock: .files) {
            let files = FileManager.checked
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.blockingWrite(to: url, options: .atomic)
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
