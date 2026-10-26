import Darwin
public import Foundation
import CmuxNextCompat

/// NIGHTLY's adoption of the shared Chief home (per-build isolation S6,
/// cx-is1kf.7; plans DESIGN section 4). NIGHTLY keeps `~/.cmux/chief/<account>`
/// in place. Before its first use of the home with this code, NIGHTLY clones
/// the home to `<chief root>/.backups/<account>-<UTC>/` (APFS clones, sockets
/// and other special files skipped) and records it in `<home>/adopted.json`
/// `{by, at, backup}`. Idempotent: a home with `adopted.json` is adopted.
///
/// It runs while the app holds the home's host lock (`state/host.lock`), so no
/// brain writes the memory (`optchat/`) during the clone; a brain of another
/// build that holds the lock defers the adoption to a later launch. It runs
/// before this app starts the conversation owner, but an owner of an earlier
/// launch usually still runs (it outlives the app) and writes `tui/`: every
/// SQLite database is copied with SQLite's online backup (consistent while a
/// writer runs, one self-contained file) and its `-wal`/`-shm`/`-journal`
/// files are not copied (hq-6d, 2026-10-14).
public nonisolated struct ChiefAdoption: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Cloned to this folder (nil: the home was empty, nothing to keep).
        case adopted(backup: URL?)
        /// `adopted.json` was there, or this is no NIGHTLY home.
        case nothingToDo
        /// Another host holds the home's lock; retried at the next launch.
        case busy
    }

    static let recordName = "adopted.json"

    public let home: ChiefHome

    public init(home: ChiefHome) {
        self.home = home
    }

    /// Whether this home is NIGHTLY's (the only one that is adopted).
    public var applies: Bool { !home.isolated && home.buildID == ChiefHome.nightlyBundleID }

    /// Clones and records the home once. `by` names the adopting build.
    public func run(by: String, now: Date = Date()) throws -> Outcome {
        let record = home.root.appendingPathComponent(Self.recordName)
        guard applies, !FileManager.checked.fileExists(atPath: record.path) else { return .nothingToDo }
        let lockPath = home.root.appendingPathComponent("state/host.lock")
        try FileManager.checked.createDirectory(at: lockPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let lock = ChiefMigration.HostLock(path: lockPath) else { return .busy }
        defer { lock.release() }
        guard !FileManager.checked.fileExists(atPath: record.path) else { return .nothingToDo }
        let names = (try? FileManager.checked.contentsOfDirectory(atPath: home.root.path)) ?? []
        var backup: URL?
        var raw: [String] = []
        if names.contains(where: { $0 != "state" }) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
            let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "")
            let backups = home.root.deletingLastPathComponent().appendingPathComponent(".backups", isDirectory: true)
            try FileManager.checked.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = backups.appendingPathComponent("\(home.root.lastPathComponent)-\(stamp)", isDirectory: true)
            guard !FileManager.checked.fileExists(atPath: target.path) else { return .busy }
            // Cloned under a hidden name and renamed when complete: a failed
            // clone leaves no backup that looks whole, and no partial copy.
            let partial = backups.appendingPathComponent(".partial-\(UUID().uuidString)", isDirectory: true)
            do {
                try Self.cloneTree(from: home.root, to: partial, raw: &raw)
                try FileManager.checked.moveItem(at: partial, to: target)
            } catch {
                try? FileManager.checked.removeItem(at: partial)
                throw error
            }
            backup = target
        }
        let json: [String: Any] = ["by": by, "at": ISO8601DateFormatter().string(from: now),
                                   "backup": backup?.path ?? NSNull(), "raw": raw]
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: record, options: .atomic)
        return .adopted(backup: backup)
    }

    /// Copies `source` to `target` (which must not exist): folders with
    /// their modes, regular files as APFS clones (a byte copy where cloning
    /// fails), symbolic links as links; sockets, FIFOs and devices skipped.
    /// The top folder is followed when it is a link (the home may be one).
    /// A SQLite database goes through the online backup; one it cannot read
    /// (not busy: corrupt, locked in another way, out of space) is cloned
    /// raw with its journal files and named in `raw`, so the backup still ends.
    static func cloneTree(from source: URL, to target: URL, top: Bool = true, raw: inout [String]) throws {
        var info = stat()
        guard (top ? blockingStat(source.path, &info) : blockingLstat(source.path, &info)) == 0 else { throw Self.posixError() }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw POSIXError(.ENOTDIR) }
        // Writable while its children are made; the source's mode at the end.
        guard blockingMkdir(target.path, 0o700) == 0 else { throw Self.posixError() }
        defer { try? FileManager.checked.setAttributes([.posixPermissions: Int(info.st_mode & 0o7777)], ofItemAtPath: target.path) }
        let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
        let databases = Set(names.filter { Self.isSQLite(source.appendingPathComponent($0)) })
        for name in names where !Self.isSidecar(name, of: databases) {
            let from = source.appendingPathComponent(name), to = target.appendingPathComponent(name)
            var entry = stat()
            guard blockingLstat(from.path, &entry) == 0 else { continue }
            switch entry.st_mode & S_IFMT {
            case S_IFDIR:
                try cloneTree(from: from, to: to, top: false, raw: &raw)
            case S_IFREG where databases.contains(name):
                do {
                    try Self.backUpDatabase(from: from, to: to)
                } catch let error as BackupError where error.busy {
                    throw error
                } catch {
                    try? FileManager.default.removeItem(at: to)
                    for file in [name] + ["-wal", "-shm", "-journal"].map({ name + $0 }) where names.contains(file) {
                        try Self.cloneFile(from: source.appendingPathComponent(file), to: target.appendingPathComponent(file))
                    }
                    raw.append(from.path)
                }
            case S_IFREG:
                try Self.cloneFile(from: from, to: to)
            case S_IFLNK:
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: from.path)
                try FileManager.default.createSymbolicLink(atPath: to.path, withDestinationPath: destination)
            default:
                continue
            }
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
