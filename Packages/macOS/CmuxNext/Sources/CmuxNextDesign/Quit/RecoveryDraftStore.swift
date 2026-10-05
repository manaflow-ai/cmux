import CmuxNextWakeups
import CryptoKit
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
    /// The checks are synchronous: `.tooLarge` and `.invalidID` mean no
    /// draft is kept for this update. `id` is the participant's id,
    /// `file:<host id>:<canonical path>`; `host` (nil: the id's host) and
    /// `filePath` must agree with it. `base` is the file state the edits are
    /// based on, taken by the participant when it read or last saved the
    /// file; the launch check compares the file with it. Without a base the
    /// draft records the file's date and size at the delayed write.
    @discardableResult
    public func update(id: String, title: String, contents: Data, host: String? = nil,
                       filePath: String? = nil, base: RecoveryDraftBase? = nil) -> RecoveryDraftAcceptance {
        let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "recovery-drafts")
        guard let parts = QuitParticipantID.parse(id) else {
            logger.error("refused recovery draft id (\(QuitParticipantID.shape(id), privacy: .public))")
            return .invalidID
        }
        guard host.map({ $0 == parts.host }) ?? true, filePath.map({ $0 == parts.path }) ?? true else {
            logger.error("refused recovery draft: its host or file path disagrees with its id")
            return .invalidID
        }
        guard contents.count <= maxDraftBytes else { return .tooLarge }
        let base = base.flatMap { $0.isEmpty ? nil : $0 }
        pending[id] = RecoveryDraft(id: id, host: parts.host, title: title, savedAt: Date(), contents: contents, filePath: filePath,
                                    fileModified: base?.modified, fileSize: base?.size, base: base)
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

    /// Whether the document's file differs from the draft's base, or (with
    /// no base) changed after the draft was written. A draft of another host
    /// is never compared with a local file.
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

    /// With no base, records the file's date and size now; then writes
    /// temp + fsync + rename.
    @concurrent static func write(_ draft: RecoveryDraft, in directory: URL, maxTotalBytes: Int) async {
        var draft = draft
        if draft.base == nil, draft.host == QuitParticipantID.localHost, let path = draft.filePath,
           let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
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
        guard draft.host == QuitParticipantID.localHost, let path = draft.filePath else { return false }
        if let base = draft.base, !base.isEmpty { return !matches(base, path: path) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return draft.fileSize != nil }
        let modified = attributes[.modificationDate] as? Date
        let size = (attributes[.size] as? NSNumber)?.int64Value
        return modified != draft.fileModified || size != draft.fileSize
    }

    /// Whether the file is still `base`: the hash alone decides when the
    /// base has one, else the date and the size that it has. A missing file
    /// is not its base.
    static func matches(_ base: RecoveryDraftBase, path: String) -> Bool {
        if let hash = base.contentHash { return sha256(path) == hash.lowercased() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        if let modified = base.modified, attributes[.modificationDate] as? Date != modified { return false }
        if let size = base.size, (attributes[.size] as? NSNumber)?.int64Value != size { return false }
        return true
    }

    /// Lowercase hex SHA-256 of the file, read in 1 MB chunks; nil when it
    /// cannot be read.
    static func sha256(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // concurrency-allow: called only from @concurrent changedSince, never on the main actor
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
