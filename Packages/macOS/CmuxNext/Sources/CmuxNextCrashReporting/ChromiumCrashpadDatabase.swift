import CmuxNextCompat
public import Foundation
import os

/// The Chromium Host's Crashpad database (`<host data folder>/Crashpad`, browser_host_main.mm), read
/// for dumps cmux has not seen (p01-process task 226). Crashpad writes each dump into `new/`, then
/// renames it into `pending/` before the crashed process may end (no upload URL: it stays there; an
/// uploaded or skipped one moves to `completed/`). Crashpad prunes the database itself
/// (`MaxDatabaseSizeInMb`, `MaxDatabaseAgeInDays` in crash_reporter.cfg); cmux never deletes a dump.
///
/// The names already seen are kept in `stateFile`. The first read with no state marks every dump
/// there as seen and returns none, as ``SystemCrashForwarder`` treats reports from before its
/// first run. Blocking (directory listings, file reads): call ``takeNew()`` on a files lane.
public nonisolated struct ChromiumCrashpadDatabase: Sendable {
    /// The database folder.
    public let directory: URL
    /// The seen dump names.
    public let stateFile: URL
    /// The most dumps one read returns (the newest); older unseen ones are marked seen unread.
    public var limit = 16
    /// Dumps larger than this are marked seen unread.
    static let maxDumpBytes = 64 << 20

    struct State: Codable, Equatable {
        var seen: [String]
    }

    public init(directory: URL, stateFile: URL) {
        self.directory = directory
        self.stateFile = stateFile
    }

    /// The dumps written since the last read, oldest first, each read and parsed; symbols empty.
    public func takeNew() -> [ChromiumMinidumpReport] {
        let present = dumps()
        let names = present.map(\.url.lastPathComponent)
        guard let state = loadState() else {
            save(State(seen: names.sorted()))
            return []
        }
        let seen = Set(state.seen)
        let fresh = present.filter { !seen.contains($0.url.lastPathComponent) }.sorted { $0.date < $1.date }.suffix(limit)
        if !fresh.isEmpty || Set(names) != seen { save(State(seen: names.sorted())) }
        return fresh.compactMap { $0.size <= Self.maxDumpBytes ? read($0.url, date: $0.date) : nil }
    }

    /// Every `.dmp` in `pending/` and `completed/` with its modification date.
    func dumps() -> [(url: URL, date: Date, size: Int)] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        return ["pending", "completed"].flatMap { folder -> [(url: URL, date: Date, size: Int)] in
            let urls = (try? FileManager.checked.contentsOfDirectory(
                at: directory.appending(path: folder, directoryHint: .isDirectory), includingPropertiesForKeys: Array(keys))) ?? []
            return urls.filter { $0.pathExtension == "dmp" }.compactMap { url in
                guard let values = try? url.blockingResourceValues(forKeys: keys) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
        }
    }

    func read(_ url: URL, date: Date) -> ChromiumMinidumpReport? {
        guard let data = try? Data(blockingContentsOf: url, options: .mappedIfSafe) else { return nil }
        do {
            return ChromiumMinidumpReport(date: date, file: url, dump: try ChromiumMinidump(data: data))
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
                .error("unreadable Chromium dump \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func loadState() -> State? {
        guard let data = try? Data(blockingContentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    func save(_ state: State) {
        do {
            try FileManager.checked.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).blockingWrite(to: stateFile, options: .atomic)
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "crash")
                .error("Chromium dump state not saved: \(String(describing: error), privacy: .public)")
        }
    }
}
