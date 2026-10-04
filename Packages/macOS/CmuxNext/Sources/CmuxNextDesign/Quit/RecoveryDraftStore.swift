import CmuxNextWakeups
public import Foundation
import os

/// The recovery-draft backstop (R96 quit hook). Participants call `update`
/// on every edit; after a short debounce on the injected clock the draft is
/// written crash-safe (temp file, fsync, rename) off the main actor, in a
/// 0700 directory as a 0600 file. `remove` (a normal save, a quit save, or
/// Don't Save) cancels a pending update first, so a stale draft never comes
/// back. The next launch reads `drafts()` and shows the restore notice.
@MainActor
public final class RecoveryDraftStore {
    public static let shared = RecoveryDraftStore(directory: RecoveryDraftFiles.defaultDirectory)
    public static let defaultMaxDraftBytes = 8 * 1024 * 1024
    public static let defaultMaxTotalBytes = 100 * 1024 * 1024

    public let directory: URL
    /// Opens a recovered draft in its editor (set by the editor side at launch).
    public var restoreHandler: ((RecoveryDraft) -> Void)?
    private let clock: any Clock<Duration>
    private let debounce: Duration
    private let maxDraftBytes: Int
    private let maxTotalBytes: Int
    private var timers: [String: DemandTimer] = [:]
    private var pending: [String: RecoveryDraft] = [:]

    public init(directory: URL, clock: any Clock<Duration> = ContinuousClock(), debounce: Duration = .seconds(1),
                maxDraftBytes: Int = RecoveryDraftStore.defaultMaxDraftBytes,
                maxTotalBytes: Int = RecoveryDraftStore.defaultMaxTotalBytes) {
        self.directory = directory
        self.clock = clock
        self.debounce = debounce
        self.maxDraftBytes = maxDraftBytes
        self.maxTotalBytes = maxTotalBytes
    }

    /// Records the current unsaved contents; written after the debounce.
    /// The size check is synchronous: `.tooLarge` means no draft is kept for
    /// this update.
    @discardableResult
    public func update(id: String, title: String, contents: Data, host: String = "local",
                       filePath: String? = nil) -> RecoveryDraftAcceptance {
        guard contents.count <= maxDraftBytes else { return .tooLarge }
        pending[id] = RecoveryDraft(id: id, host: host, title: title, savedAt: Date(), contents: contents, filePath: filePath)
        let timer = timers[id] ?? DemandTimer(owner: "recovery-draft", clock: clock)
        timers[id] = timer
        timer.schedule(after: debounce) { @MainActor [weak self] in await self?.writeNow(id) }
        return .kept
    }

    /// Drops the draft of `id` and any update still waiting for its debounce.
    public func remove(id: String) async {
        timers.removeValue(forKey: id)?.cancel()
        pending[id] = nil
        await RecoveryDraftFiles.delete(id: id, in: directory)
    }

    /// Writes every pending update now (a quit that cannot wait).
    public func writePending() async {
        for id in Array(pending.keys) {
            timers.removeValue(forKey: id)?.cancel()
            await writeNow(id)
        }
    }

    /// Every draft on disk (read at launch).
    public func drafts() async -> [RecoveryDraft] {
        await RecoveryDraftFiles.readAll(in: directory)
    }

    /// Whether the document's file changed after the draft was written.
    public func fileChangedSince(_ draft: RecoveryDraft) async -> Bool {
        await RecoveryDraftFiles.changedSince(draft)
    }

    private func writeNow(_ id: String) async {
        guard let draft = pending.removeValue(forKey: id) else { return }
        timers[id] = nil
        await RecoveryDraftFiles.write(draft, in: directory, maxTotalBytes: maxTotalBytes)
    }
}

/// The draft files, all IO off the main actor.
nonisolated enum RecoveryDraftFiles {
    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("cmux/recovery", isDirectory: true)
    }

    static func fileName(_ id: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0100_0000_01b3
        }
        return String(format: "%016llx.draft", hash)
    }

    /// Records the file's date and size, then writes temp + fsync + rename.
    @concurrent static func write(_ draft: RecoveryDraft, in directory: URL, maxTotalBytes: Int) async {
        var draft = draft
        if let path = draft.filePath, let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            draft.fileModified = attributes[.modificationDate] as? Date
            draft.fileSize = (attributes[.size] as? NSNumber)?.int64Value
        }
        guard let data = try? JSONEncoder().encode(draft) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var backupless = directory
        try? backupless.setResourceValues(excluded)
        let target = directory.appendingPathComponent(fileName(draft.id))
        let temp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        // concurrency-allow: @concurrent RecoveryDraftFiles.write, never on the main actor
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, rename(temp.path, target.path) == 0 else {
            unlink(temp.path)
            return
        }
        evictOldest(in: directory, keeping: target, maxTotalBytes: maxTotalBytes)
    }

    /// Over the total cap: the oldest drafts go first (never the one just
    /// written); each eviction is logged by draft id only, never contents.
    static func evictOldest(in directory: URL, keeping kept: URL, maxTotalBytes: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? [])
            .filter { $0.pathExtension == "draft" }
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        func date(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var total = files.reduce(0) { $0 + size($1) }
        for file in files.sorted(by: { date($0) < date($1) }) where total > maxTotalBytes && file.standardizedFileURL != kept.standardizedFileURL {
            total -= size(file)
            unlink(file.path)
            Logger(subsystem: "com.cmuxterm.app.next", category: "recovery-drafts")
                .notice("evicted recovery draft \(file.deletingPathExtension().lastPathComponent, privacy: .public) (store over its size cap)")
        }
    }

    @concurrent static func delete(id: String, in directory: URL) async {
        unlink(directory.appendingPathComponent(fileName(id)).path)
    }

    @concurrent static func readAll(in directory: URL) async -> [RecoveryDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "draft" }
            .compactMap { file in
                // concurrency-allow: @concurrent, off the main actor
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(RecoveryDraft.self, from: data)
            }
            .sorted { $0.savedAt < $1.savedAt }
    }

    @concurrent static func changedSince(_ draft: RecoveryDraft) async -> Bool {
        guard let path = draft.filePath else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return draft.fileSize != nil }
        let modified = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.int64Value
        return modified != draft.fileModified || size != draft.fileSize
    }
}
