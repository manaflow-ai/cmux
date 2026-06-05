import Foundation
import OSLog

private let focusHistoryLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "FocusHistoryStore"
)

/// A persisted store for focus history entries.
///
/// Focus history tracks which workspaces and panels the user has focused,
/// enabling back/forward navigation and a browsable history pane.
/// Unlike the in-memory focus history that was capped at 50 entries,
/// this store persists permanently to disk with no capacity limit.
@MainActor
final class FocusHistoryStore: ObservableObject {
    static let shared = FocusHistoryStore(
        fileURL: defaultHistoryFileURL()
    )

    @Published private(set) var revision: UInt64 = 0
    private var records: [FocusHistoryRecord] = []
    private let fileURL: URL?
    private var needsPersistenceAfterLoad = false
    private var didFinishLoad = false

    init(fileURL: URL? = nil, loadPersisted: Bool = true) {
        self.fileURL = fileURL
        self.didFinishLoad = !loadPersisted || fileURL == nil
        if loadPersisted, let fileURL {
            loadPersistedRecordsAsync(from: fileURL)
        }
    }

    var isEmpty: Bool { records.isEmpty }
    var count: Int { records.count }

    var allRecords: [FocusHistoryRecord] { records }

    func record(for index: Int) -> FocusHistoryRecord? {
        guard records.indices.contains(index) else { return nil }
        return records[index]
    }

    func append(_ record: FocusHistoryRecord) {
        records.append(record)
        revision &+= 1
        persistRecords()
    }

    func insert(_ record: FocusHistoryRecord, at index: Int) {
        let insertionIndex = min(max(0, index), records.count)
        records.insert(record, at: insertionIndex)
        revision &+= 1
        persistRecords()
    }

    func remove(at index: Int) -> FocusHistoryRecord? {
        guard records.indices.contains(index) else { return nil }
        let record = records.remove(at: index)
        revision &+= 1
        persistRecords()
        return record
    }

    func removeAll() {
        guard !records.isEmpty else { return }
        records.removeAll(keepingCapacity: false)
        revision &+= 1
        persistRecords()
    }

    func removeAll(where predicate: (FocusHistoryRecord) -> Bool) {
        let oldCount = records.count
        records.removeAll(where: predicate)
        guard records.count != oldCount else { return }
        revision &+= 1
        persistRecords()
    }

    func replaceAll(_ newRecords: [FocusHistoryRecord]) {
        records = newRecords
        revision &+= 1
        persistRecords()
    }

    func updateRecord(at index: Int, with record: FocusHistoryRecord) {
        guard records.indices.contains(index) else { return }
        records[index] = record
        revision &+= 1
        persistRecords()
    }

    // MARK: - Persistence

    private func persistRecords() {
        guard let fileURL else { return }
        guard didFinishLoad else {
            needsPersistenceAfterLoad = true
            return
        }
        let snapshot = records
        Task.detached(priority: .utility) {
            Self.saveRecords(snapshot, fileURL: fileURL)
        }
    }

    private func loadPersistedRecordsAsync(from fileURL: URL) {
        Task { @MainActor [weak self] in
            let loaded = await Self.loadRecords(fileURL: fileURL)
            guard let self, !self.didFinishLoad else { return }
            self.records = loaded
            self.didFinishLoad = true
            self.revision &+= 1
            if self.needsPersistenceAfterLoad {
                self.needsPersistenceAfterLoad = false
                self.persistRecords()
            }
        }
    }

    nonisolated private static func loadRecords(fileURL: URL) -> [FocusHistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(FocusHistoryPersistenceSnapshot.self, from: data),
           snapshot.version == FocusHistoryPersistenceSnapshot.currentVersion {
            return snapshot.records
        }
        return (try? decoder.decode([FocusHistoryRecord].self, from: data)) ?? []
    }

    nonisolated private static func saveRecords(_ records: [FocusHistoryRecord], fileURL: URL) {
        guard !records.isEmpty else {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    focusHistoryLogger.debug(
                        "focusHistory.remove.failed file=\(fileURL.path, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            return
        }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let snapshot = FocusHistoryPersistenceSnapshot(records: records)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            if let existingData = try? Data(contentsOf: fileURL), existingData == data {
                return
            }
            try data.write(to: fileURL, options: .atomic)
        } catch {
            focusHistoryLogger.debug(
                "focusHistory.save.failed file=\(fileURL.path, privacy: .public) records=\(records.count) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    nonisolated private static func defaultHistoryFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appSupportDirectory: URL? = nil,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests else { return nil }
        let resolvedAppSupport: URL
        if let appSupportDirectory {
            resolvedAppSupport = appSupportDirectory
        } else if let discovered = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            resolvedAppSupport = discovered
        } else {
            return nil
        }
        let bundleId = (bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? bundleIdentifier!
            : "com.cmuxterm.app"
        let safeBundleId = bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        return resolvedAppSupport
            .appendingPathComponent("cmux", isDirectory: true)
            .appendingPathComponent("focus-history-\(safeBundleId).json", isDirectory: false)
    }
}

private struct FocusHistoryPersistenceSnapshot: Codable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var records: [FocusHistoryRecord]
}
