#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextCompat
public import Foundation
import os

/// Where invariant violation reports go (plans/cmux-next/invariants-DESIGN.md section 4):
/// `~/Library/Logs/cmux-next/<tag>/invariants/` (`release` for untagged builds), one JSON file per pass that found
/// new violations, `<first seq>-<rule>[+<more>].json`. The app reads the report's facts once per batch in a turn of
/// its own after the violating frame; encoding (the rules' states included) and the write run on the files lane, off
/// the main actor, and the newest ``keep`` files stay.
public struct InvariantReportStore: Sendable {
    /// Reports kept on disk per build; older ones are deleted.
    public static let keep = 50

    public let directory: URL?
    /// The app's blocking-work lanes: the report writes run there, never on the pool.
    let runner: any MayBlockRunner

    public init(tag: String?, runner: any MayBlockRunner,
                logs: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first) {
        directory = logs?.appending(path: "Logs/cmux-next/\(tag ?? "release")/invariants", directoryHint: .isDirectory)
        self.runner = runner
    }

    /// The report file of a batch whose first violation is `first` (`0041-W10.json`; `0041-W10+2.json` when two
    /// more violations of the same pass share it).
    public func url(first: InvariantViolation, count: Int = 1) -> URL? {
        let id = String(first.id.rawValue.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        let more = count > 1 ? "+\(count - 1)" : ""
        return directory?.appending(path: String(format: "%04llu-", first.seq) + id + more + ".json")
    }

    /// Writes the report `make` encodes for the batch that starts with `first` and prunes old reports, on the runner's
    /// files lane; then calls `written` there with the file and the rules' states `make` encoded (by sequence
    /// number), so the ledger names a report only once it exists.
    public func write(first: InvariantViolation, count: Int,
                      _ make: @escaping @Sendable () -> (file: Data, states: [UInt64: Data]),
                      written: @escaping @Sendable (URL, [UInt64: Data]) -> Void) {
        guard let directory, let url = url(first: first, count: count) else { return }
        runner.postFiles(.bestEffort, shutdown: .continueOnShutdown) {
            let files = FileManager.checked
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                let made = make()
                try made.file.blockingWrite(to: url, options: .atomic)
                let existing = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for old in existing.dropLast(Self.keep) { try? files.removeItem(at: old) }
                written(url, made.states)
            } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "app.invariants")
                    .error("invariant report write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
#endif
