#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextInvariants
#endif
import CmuxNextSettings
import Foundation
import os
import CmuxNextCompat

/// Where invariant violation reports go (plans/cmux-next/invariants-DESIGN.md section 4):
/// `~/Library/Logs/cmux-next/<tag>/invariants/` (`release` for untagged builds), one JSON file per violation with
/// the rule's state, the input journal that led there (`debug.replay`, `scripts/cmux-next/input-replay.py`) and the
/// focus, surface and layer reports. Encoding and writes happen on the files lane, off the main actor.
nonisolated struct InvariantReportStore: Sendable {
    /// Reports kept on disk per build; older ones are deleted.
    static let keep = 50

    let directory: URL?
    /// The app's blocking-work lanes: the report writes run there, never on the pool.
    let runner: any MayBlockRunner

    init(tag: String?, runner: any MayBlockRunner,
         logs: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first) {
        directory = logs?.appending(path: "Logs/cmux-next/\(tag ?? "release")/invariants", directoryHint: .isDirectory)
        self.runner = runner
    }

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

    /// `value` as JSON, sorted keys (null when it does not encode).
    static func json(_ value: some Encodable) -> JSONValue {
        guard let data = try? encoder.encode(value) else { return .null }
        return (try? JSONValue.parse(data)) ?? .null
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The report file of `violation`: its sequence number and rule id (`0041-W10.json`).
    func url(for violation: InvariantViolation) -> URL? {
        let id = String(violation.id.rawValue.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return directory?.appending(path: String(format: "%04llu-", violation.seq) + id + ".json")
    }

    /// Writes the report `make` encodes for `violation` and prunes old reports, on the runner's files lane.
    func write(for violation: InvariantViolation, _ make: @escaping @Sendable () -> Data) {
        guard let directory, let url = url(for: violation) else { return }
        runner.postFiles(.bestEffort, shutdown: .continueOnShutdown) {
            let files = FileManager.default
            do {
                try files.createDirectory(at: directory, withIntermediateDirectories: true)
                try make().write(to: url, options: .atomic)
                let existing = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "json" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                for old in existing.dropLast(Self.keep) { try? files.removeItem(at: old) }
            } catch {
                Logger(subsystem: "com.cmuxterm.app.next", category: "app.invariants")
                    .error("invariant report write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
    #endif
}
