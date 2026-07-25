import Foundation
import os

nonisolated private let notificationFeedPersistenceLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "notification-feed-persistence"
)

/// The durable feed's startup state. Unsupported snapshots remain intact and
/// put persistence into a read-only mode until this version of cmux exits.
nonisolated enum NotificationFeedHistoryLoadOutcome: Equatable, Sendable {
    case missing
    case loaded(NotificationFeedHistorySnapshot)
    case corrupt
    case unsupportedVersion(Int)
}

/// Owns all notification-feed disk access, including the initial read, so JSON
/// work never runs on the main actor. Writes are serialized and stale revisions
/// are rejected.
actor NotificationFeedHistoryPersistence {
    private static let titleByteLimit = 512
    private static let subtitleByteLimit = 512
    private static let bodyByteLimit = 2_048
    private static let oversizedSnapshotHeaderChunkByteCount = 64 * 1024

    private struct SnapshotHeader {
        var version: Int?
        var revision: Int?

        var isComplete: Bool {
            version != nil && revision != nil
        }
    }

    private enum HeaderKeyOccurrence {
        case first
        case last
    }

    private let fileURL: URL?
    private let fileManager: FileManager
    private let readRetentionLimit: Int
    private let totalRetentionLimit: Int
    private let maxSnapshotBytes: UInt64
    private var lastPersistedRevision = 0
    private var loadOutcome: NotificationFeedHistoryLoadOutcome?
    private var allowsWrites = true

    init(
        fileURL: URL?,
        fileManager: FileManager,
        readRetentionLimit: Int = NotificationFeedHistoryStore.readRetentionLimit,
        totalRetentionLimit: Int = NotificationFeedHistoryStore.totalRetentionLimit,
        maxSnapshotBytes: UInt64? = nil
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.readRetentionLimit = max(0, readRetentionLimit)
        self.totalRetentionLimit = max(0, totalRetentionLimit)
        self.maxSnapshotBytes = maxSnapshotBytes ?? Self.defaultMaxSnapshotBytes(
            totalRetentionLimit: self.totalRetentionLimit
        )
    }

    func load() -> NotificationFeedHistoryLoadOutcome {
        if let loadOutcome { return loadOutcome }
        guard let fileURL else {
            let outcome = NotificationFeedHistoryLoadOutcome.missing
            loadOutcome = outcome
            return outcome
        }
        restoreNewestQuarantineBackupIfNeeded(for: fileURL)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            let outcome = NotificationFeedHistoryLoadOutcome.missing
            loadOutcome = outcome
            return outcome
        }

        let outcome: NotificationFeedHistoryLoadOutcome
        do {
            guard try snapshotFileFitsLoadBudget(fileURL) else {
                notificationFeedPersistenceLogger.error(
                    "Notification feed load rejected oversized file=\(fileURL.path, privacy: .private) limit=\(self.maxSnapshotBytes, privacy: .public)"
                )
                let header = try oversizedSnapshotHeader(fileURL)
                if let version = header.version,
                   version != NotificationFeedHistorySnapshot.currentVersion {
                    allowsWrites = false
                    outcome = .unsupportedVersion(version)
                } else if header.version == NotificationFeedHistorySnapshot.currentVersion,
                          let revision = header.revision {
                    do {
                        let snapshot = NotificationFeedHistorySnapshot(
                            revision: max(0, revision),
                            notifications: []
                        )
                        try replaceOversizedSnapshotFile(
                            fileURL,
                            replacementSnapshot: snapshot
                        )
                        lastPersistedRevision = snapshot.revision
                        outcome = .loaded(snapshot)
                    } catch {
                        allowsWrites = false
                        outcome = .corrupt
                    }
                } else {
                    allowsWrites = false
                    outcome = .corrupt
                }
                loadOutcome = outcome
                return outcome
            }
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(NotificationFeedHistorySnapshot.self, from: data)
            guard decoded.version == NotificationFeedHistorySnapshot.currentVersion else {
                allowsWrites = false
                outcome = .unsupportedVersion(decoded.version)
                loadOutcome = outcome
                return outcome
            }
            let decodedSnapshot = NotificationFeedHistorySnapshot(
                revision: max(0, decoded.revision),
                notifications: decoded.notifications
            )
            guard let fitted = try snapshotAndDataFittingLoadBudget(decodedSnapshot) else {
                notificationFeedPersistenceLogger.error(
                    "Notification feed load could not fit decoded file=\(fileURL.path, privacy: .private) limit=\(self.maxSnapshotBytes, privacy: .public)"
                )
                allowsWrites = false
                outcome = .corrupt
                loadOutcome = outcome
                return outcome
            }
            let snapshot = fitted.snapshot
            compactLoadedSnapshotIfNeeded(
                snapshot,
                encodedData: fitted.data,
                originalSnapshot: decoded,
                fileURL: fileURL
            )
            lastPersistedRevision = snapshot.revision
            outcome = .loaded(snapshot)
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed load failed file=\(fileURL.path, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
            outcome = .corrupt
        }
        loadOutcome = outcome
        return outcome
    }

    private static func defaultMaxSnapshotBytes(totalRetentionLimit: Int) -> UInt64 {
        let minimumBudget = UInt64(1_048_576)
        let perRecordBudget = UInt64(2_048)
        let maximumWireCompatibleBudget = UInt64(4 * 1024 * 1024)
        let retainedRecordBudget = UInt64(max(1, totalRetentionLimit)) * perRecordBudget
        return min(max(minimumBudget, retainedRecordBudget), maximumWireCompatibleBudget)
    }

    private func snapshotFileFitsLoadBudget(_ fileURL: URL) throws -> Bool {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber else { return true }
        return size.uint64Value <= maxSnapshotBytes
    }

    private func oversizedSnapshotHeader(_ fileURL: URL) throws -> SnapshotHeader {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? handle.close()
        }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        let prefixData = try handle.read(
            upToCount: Self.oversizedSnapshotHeaderChunkByteCount
        ) ?? Data()
        var header = Self.snapshotHeader(
            in: prefixData,
            occurrence: .first
        )
        guard !header.isComplete,
              fileSize > UInt64(Self.oversizedSnapshotHeaderChunkByteCount) else {
            return header
        }

        let tailOffset = fileSize - UInt64(Self.oversizedSnapshotHeaderChunkByteCount)
        try handle.seek(toOffset: tailOffset)
        let tailData = try handle.read(
            upToCount: Self.oversizedSnapshotHeaderChunkByteCount
        ) ?? Data()
        let tailHeader = Self.snapshotHeader(in: tailData, occurrence: .last)
        header.version = header.version ?? tailHeader.version
        header.revision = header.revision ?? tailHeader.revision
        return header
    }

    private static func snapshotHeader(
        in data: Data,
        occurrence: HeaderKeyOccurrence
    ) -> SnapshotHeader {
        let text = String(decoding: data, as: UTF8.self)
        return SnapshotHeader(
            version: jsonIntegerValue(named: "version", in: text, occurrence: occurrence),
            revision: jsonIntegerValue(named: "revision", in: text, occurrence: occurrence)
        )
    }

    private static func jsonIntegerValue(
        named key: String,
        in text: String,
        occurrence: HeaderKeyOccurrence
    ) -> Int? {
        let needle = "\"\(key)\""
        let range: Range<String.Index>?
        switch occurrence {
        case .first:
            range = text.range(of: needle)
        case .last:
            range = text.range(of: needle, options: .backwards)
        }
        guard let range else { return nil }
        var index = range.upperBound
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        guard index < text.endIndex, text[index] == ":" else { return nil }
        index = text.index(after: index)
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        let valueStart = index
        if index < text.endIndex, text[index] == "-" {
            index = text.index(after: index)
        }
        let digitStart = index
        while index < text.endIndex, text[index].isNumber {
            index = text.index(after: index)
        }
        guard digitStart < index else { return nil }
        let literal = String(text[valueStart..<index])
        return Int(literal)
    }

    private func replaceOversizedSnapshotFile(
        _ fileURL: URL,
        replacementSnapshot snapshot: NotificationFeedHistorySnapshot
    ) throws {
        let replacementURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(fileURL.lastPathComponent).replacement-\(UUID().uuidString).tmp",
                isDirectory: false
            )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: replacementURL, options: .atomic)
            let backupName = "\(fileURL.lastPathComponent).oversized-\(UUID().uuidString).quarantine"
            let backupURL = fileURL
                .deletingLastPathComponent()
                .appendingPathComponent(backupName, isDirectory: false)
            try fileManager.copyItem(at: fileURL, to: backupURL)
            _ = try fileManager.replaceItemAt(
                fileURL,
                withItemAt: replacementURL,
                backupItemName: nil,
                options: []
            )
            notificationFeedPersistenceLogger.notice(
                "Notification feed oversized file replaced file=\(fileURL.path, privacy: .private) backup=\(backupName, privacy: .private) revision=\(snapshot.revision, privacy: .public)"
            )
        } catch {
            try? fileManager.removeItem(at: replacementURL)
            notificationFeedPersistenceLogger.error(
                "Notification feed oversized file replacement failed file=\(fileURL.path, privacy: .private) revision=\(snapshot.revision, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    private func quarantineBackupURLs(for fileURL: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("\(fileURL.lastPathComponent).oversized-")
                && $0.lastPathComponent.hasSuffix(".quarantine")
        }
    }

    private func newestQuarantineBackupURL(for fileURL: URL) throws -> URL? {
        try quarantineBackupURLs(for: fileURL).max { lhs, rhs in
            let lhsValues = try? lhs.resourceValues(forKeys: [.contentModificationDateKey])
            let rhsValues = try? rhs.resourceValues(forKeys: [.contentModificationDateKey])
            let lhsDate = lhsValues?.contentModificationDate ?? .distantPast
            let rhsDate = rhsValues?.contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }
    }

    private func restoreNewestQuarantineBackupIfNeeded(for fileURL: URL) {
        guard !fileManager.fileExists(atPath: fileURL.path),
              let backupURL = try? newestQuarantineBackupURL(for: fileURL) else {
            return
        }
        do {
            try fileManager.moveItem(at: backupURL, to: fileURL)
            notificationFeedPersistenceLogger.notice(
                "Notification feed quarantine restored missing canonical file=\(fileURL.path, privacy: .private) backup=\(backupURL.path, privacy: .private)"
            )
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed quarantine restore failed missing canonical file=\(fileURL.path, privacy: .private) backup=\(backupURL.path, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func compactLoadedSnapshotIfNeeded(
        _ snapshot: NotificationFeedHistorySnapshot,
        encodedData: Data,
        originalSnapshot: NotificationFeedHistorySnapshot,
        fileURL: URL
    ) {
        guard snapshot != originalSnapshot else { return }
        do {
            try encodedData.write(to: fileURL, options: .atomic)
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed compaction failed file=\(fileURL.path, privacy: .private) revision=\(snapshot.revision) error=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func persist(_ snapshot: NotificationFeedHistorySnapshot) {
        _ = load()
        guard allowsWrites,
              snapshot.version == NotificationFeedHistorySnapshot.currentVersion,
              snapshot.revision > lastPersistedRevision else {
            return
        }
        let fitted: (snapshot: NotificationFeedHistorySnapshot, data: Data)
        do {
            guard let resolved = try snapshotAndDataFittingLoadBudget(snapshot) else {
                notificationFeedPersistenceLogger.error(
                    "Notification feed persist skipped because snapshot cannot fit load budget revision=\(snapshot.revision, privacy: .public) limit=\(self.maxSnapshotBytes, privacy: .public)"
                )
                return
            }
            fitted = resolved
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed persist encode failed revision=\(snapshot.revision, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            return
        }
        guard let fileURL else {
            lastPersistedRevision = fitted.snapshot.revision
            loadOutcome = .loaded(fitted.snapshot)
            return
        }

        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try fitted.data.write(to: fileURL, options: .atomic)
            lastPersistedRevision = fitted.snapshot.revision
            loadOutcome = .loaded(fitted.snapshot)
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed persist failed file=\(fileURL.path, privacy: .private) revision=\(snapshot.revision) error=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func snapshotAndDataFittingLoadBudget(
        _ snapshot: NotificationFeedHistorySnapshot
    ) throws -> (snapshot: NotificationFeedHistorySnapshot, data: Data)? {
        let normalizedRecords = Self.normalized(
            snapshot.notifications.map(Self.recordWithBoundedText),
            readRetentionLimit: readRetentionLimit,
            totalRetentionLimit: totalRetentionLimit
        )
        return try encodedSnapshot(
            revision: snapshot.revision,
            version: snapshot.version,
            records: normalizedRecords,
            maxBytes: maxSnapshotBytes
        )
    }

    private func encodedSnapshot(
        revision: Int,
        version: Int,
        records: [NotificationFeedHistoryRecord],
        maxBytes: UInt64
    ) throws -> (snapshot: NotificationFeedHistorySnapshot, data: Data)? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func encode(prefixCount: Int) throws -> (NotificationFeedHistorySnapshot, Data) {
            let snapshot = NotificationFeedHistorySnapshot(
                revision: revision,
                notifications: Array(records.prefix(prefixCount)),
                version: version
            )
            return (snapshot, try encoder.encode(snapshot))
        }

        let full = try encode(prefixCount: records.count)
        guard UInt64(full.1.count) > maxBytes else { return full }

        var lowerBound = 0
        var upperBound = records.count
        var best: (snapshot: NotificationFeedHistorySnapshot, data: Data)?
        while lowerBound <= upperBound {
            let candidateCount = (lowerBound + upperBound) / 2
            let candidate = try encode(prefixCount: candidateCount)
            if UInt64(candidate.1.count) <= maxBytes {
                best = candidate
                lowerBound = candidateCount + 1
            } else {
                upperBound = candidateCount - 1
            }
        }
        return best
    }

    private static func recordWithBoundedText(
        _ record: NotificationFeedHistoryRecord
    ) -> NotificationFeedHistoryRecord {
        NotificationFeedHistoryRecord(
            id: record.id,
            tabId: record.tabId,
            surfaceId: record.surfaceId,
            panelId: record.panelId,
            retargetsToLiveSurfaceOwner: record.retargetsToLiveSurfaceOwner,
            title: string(record.title, limitedToUTF8Bytes: titleByteLimit),
            subtitle: string(record.subtitle, limitedToUTF8Bytes: subtitleByteLimit),
            body: string(record.body, limitedToUTF8Bytes: bodyByteLimit),
            createdAt: record.createdAt,
            isRead: record.isRead
        )
    }

    private static func string(_ value: String, limitedToUTF8Bytes maxBytes: Int) -> String {
        guard maxBytes >= 0, value.utf8.count > maxBytes else { return value }
        var byteCount = 0
        var endIndex = value.startIndex
        while endIndex < value.endIndex {
            let nextIndex = value.index(after: endIndex)
            let characterByteCount = value[endIndex..<nextIndex].utf8.count
            guard byteCount + characterByteCount <= maxBytes else { break }
            byteCount += characterByteCount
            endIndex = nextIndex
        }
        return String(value[..<endIndex])
    }

    private static func normalized(
        _ records: [NotificationFeedHistoryRecord],
        readRetentionLimit: Int,
        totalRetentionLimit: Int
    ) -> [NotificationFeedHistoryRecord] {
        guard totalRetentionLimit > 0 else { return [] }
        let sorted = records.sorted(by: recordPrecedes)
        var remainingReadSlots = readRetentionLimit
        var normalized: [NotificationFeedHistoryRecord] = []
        normalized.reserveCapacity(min(sorted.count, totalRetentionLimit))
        for record in sorted {
            if record.isRead {
                guard remainingReadSlots > 0 else { continue }
                remainingReadSlots -= 1
            }
            normalized.append(record)
            if normalized.count >= totalRetentionLimit {
                break
            }
        }
        return normalized
    }

    private static func recordPrecedes(
        _ lhs: NotificationFeedHistoryRecord,
        _ rhs: NotificationFeedHistoryRecord
    ) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}
