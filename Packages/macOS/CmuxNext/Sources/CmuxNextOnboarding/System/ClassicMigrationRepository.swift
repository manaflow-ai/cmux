import CmuxNextCompat
public import Foundation

/// The classic migration's own folder: its ledger and backup copies of the classic files it read.
///
/// Classic's files are only ever read and copied, never written, moved or
/// deleted. Writes are atomic, so a crash leaves the old ledger or the new one.
///
/// ```swift
/// let repository = ClassicMigrationRepository(directory: temporaryDirectory)
/// var ledger = ClassicMigrationLedger()
/// try await repository.save(ledger)
/// ```
public actor ClassicMigrationRepository {
    /// The actor's own serial queue: its file calls block this queue, never a cooperative pool thread
    /// (Chrome runs file work on a MayBlock sequence, base/task/task_traits.h).
    private nonisolated let queue = DispatchSerialQueue(label: "com.cmuxterm.next.onboarding.classic-migration", qos: .userInitiated)

    /// Runs the actor on ``queue``.
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// How many backup folders are kept, newest first.
    public static let keptBackups = 5

    public let directory: URL

    /// - Parameter directory: the migration's folder, made on the first save
    ///   (the app passes `Application Support/cmux-next/<bundle id>/classic-migration`).
    public init(directory: URL) {
        self.directory = directory
    }

    public var ledgerURL: URL { directory.appendingPathComponent("ledger.json") }
    public var backupsURL: URL { directory.appendingPathComponent("backups", isDirectory: true) }

    /// The ledger, if any. One that does not decode is moved aside as `ledger.unreadable-<ms>.json`.
    public func load() -> ClassicMigrationLedgerLoad {
        guard let data = FileManager.checked.contents(atPath: ledgerURL.path) else { return .none }
        if let schema = (try? JSONSerialization.blockingJSONObject(with: data) as? [String: Any])?["schema"] as? Int,
           schema > ClassicMigrationLedger.currentSchema {
            return .newer(schema: schema)
        }
        if let ledger = try? JSONDecoder().blockingDecode(ClassicMigrationLedger.self, from: data) { return .ledger(ledger) }
        // wall-clock: a file name stamp, not a time.
        let aside = directory.appendingPathComponent("ledger.unreadable-\(Int(Date().timeIntervalSince1970 * 1000)).json")
        try? FileManager.checked.moveItem(at: ledgerURL, to: aside)
        return .unreadable
    }

    /// Writes `ledger` atomically.
    public func save(_ ledger: ClassicMigrationLedger) throws {
        try FileManager.checked.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(ledger).write(to: ledgerURL, options: .atomic)
    }

    /// Copies `files` that exist into a new `backups/<stamp>` folder and
    /// returns it; nil when none exists. Older folders beyond
    /// ``keptBackups`` are removed (only the migration's own copies).
    @discardableResult
    public func backup(_ files: [URL], stamp: String) throws -> URL? {
        let existing = files.filter { FileManager.checked.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return nil }
        let folder = backupsURL.appendingPathComponent(stamp, isDirectory: true)
        try FileManager.checked.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in existing {
            let copy = folder.appendingPathComponent(file.lastPathComponent)
            if FileManager.checked.fileExists(atPath: copy.path) { continue }
            try FileManager.checked.copyItem(at: file, to: copy)
        }
        let all = ((try? FileManager.checked.contentsOfDirectory(atPath: backupsURL.path)) ?? []).sorted(by: >)
        for old in all.dropFirst(Self.keptBackups) {
            try? FileManager.checked.removeItem(at: backupsURL.appendingPathComponent(old, isDirectory: true))
        }
        return folder
    }
}
