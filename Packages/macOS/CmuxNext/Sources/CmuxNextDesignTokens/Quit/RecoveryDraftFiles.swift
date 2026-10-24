package import CryptoKit
public import Foundation
package import os

/// The draft files, all IO off the main actor.
package nonisolated enum RecoveryDraftFiles {
    package static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("cmux/recovery", isDirectory: true)
    }

    package static func fileName(_ id: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0100_0000_01b3
        }
        return String(format: "%016llx.draft", hash)
    }

    /// With no base, records the file's date and size now; then writes
    /// temp + fsync + rename.
    @concurrent package static func write(_ draft: RecoveryDraft, in directory: URL, maxTotalBytes: Int) async {
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
    package static func evictOldest(in directory: URL, keeping kept: URL, maxTotalBytes: Int) {
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

    @concurrent package static func delete(id: String, in directory: URL) async {
        unlink(directory.appendingPathComponent(fileName(id)).path)
    }

    @concurrent package static func readAll(in directory: URL) async -> [RecoveryDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "draft" }
            .compactMap { file in
                // concurrency-allow: @concurrent, off the main actor
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? JSONDecoder().decode(RecoveryDraft.self, from: data)
            }
            .sorted { $0.savedAt < $1.savedAt }
    }

    @concurrent package static func changedSince(_ draft: RecoveryDraft) async -> Bool {
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
    package static func matches(_ base: RecoveryDraftBase, path: String) -> Bool {
        if let hash = base.contentHash { return sha256(path) == hash.lowercased() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        if let modified = base.modified, attributes[.modificationDate] as? Date != modified { return false }
        if let size = base.size, (attributes[.size] as? NSNumber)?.int64Value != size { return false }
        return true
    }

    /// Lowercase hex SHA-256 of the file, read in 1 MB chunks; nil when it
    /// cannot be read.
    package static func sha256(_ path: String) -> String? {
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
