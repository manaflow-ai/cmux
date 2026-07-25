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
    private static let oversizedSnapshotHeaderChunkByteCount = 64 * 1024

    private struct SnapshotHeader {
        var version: Int?
        var revision: Int?

        var isComplete: Bool {
            version != nil && revision != nil
        }
    }

    private struct TopLevelSnapshotHeaderScanner {
        var header = SnapshotHeader()
        private var depth = 0
        private var isInString = false
        private var isEscapingString = false
        private var isCapturingKey = false
        private var keyBytes: [UInt8] = []
        private var isExpectingKey = false
        private var isExpectingValue = false
        private var currentKey: String?
        private var numberKey: String?
        private var numberBytes: [UInt8] = []
        private var numberOverflowed = false

        mutating func consume(_ data: Data) {
            for byte in data {
                consume(byte)
                if header.isComplete { return }
            }
        }

        private mutating func consume(_ byte: UInt8) {
            if numberKey != nil {
                if consumeNumberByte(byte) {
                    return
                }
                finishNumber()
                consume(byte)
                return
            }

            if isInString {
                if isEscapingString {
                    isEscapingString = false
                    if isCapturingKey {
                        keyBytes.append(byte)
                    }
                    return
                }
                if byte == Self.backslash {
                    isEscapingString = true
                    if isCapturingKey {
                        keyBytes.append(byte)
                    }
                    return
                }
                if byte == Self.quote {
                    isInString = false
                    if isCapturingKey {
                        currentKey = String(bytes: keyBytes, encoding: .utf8)
                        keyBytes.removeAll(keepingCapacity: true)
                        isCapturingKey = false
                    }
                    return
                }
                if isCapturingKey {
                    keyBytes.append(byte)
                }
                return
            }

            guard !Self.isWhitespace(byte) else { return }

            switch byte {
            case Self.leftBrace, Self.leftBracket:
                if depth == 0, byte == Self.leftBrace {
                    isExpectingKey = true
                }
                depth += 1
                isExpectingValue = false
            case Self.rightBrace, Self.rightBracket:
                if depth > 0 {
                    depth -= 1
                }
                if depth == 1 {
                    currentKey = nil
                    isExpectingValue = false
                }
            case Self.comma:
                if depth == 1 {
                    currentKey = nil
                    isExpectingKey = true
                    isExpectingValue = false
                }
            case Self.colon:
                if depth == 1, currentKey != nil {
                    isExpectingKey = false
                    isExpectingValue = true
                }
            case Self.quote:
                isInString = true
                if depth == 1, isExpectingKey {
                    isCapturingKey = true
                    keyBytes.removeAll(keepingCapacity: true)
                    isExpectingKey = false
                } else {
                    isCapturingKey = false
                    isExpectingValue = false
                }
            default:
                guard depth == 1,
                      isExpectingValue,
                      let currentKey,
                      currentKey == "revision" || currentKey == "version",
                      (Self.isDigit(byte) || byte == Self.minus) else {
                    if depth == 1, isExpectingValue {
                        isExpectingValue = false
                    }
                    return
                }
                startNumber(key: currentKey)
                _ = consumeNumberByte(byte)
            }
        }

        private mutating func startNumber(key: String) {
            numberKey = key
            numberBytes.removeAll(keepingCapacity: true)
            numberOverflowed = false
            isExpectingValue = false
        }

        private mutating func consumeNumberByte(_ byte: UInt8) -> Bool {
            if byte == Self.minus, numberBytes.isEmpty {
                numberBytes.append(byte)
                return true
            }
            guard Self.isDigit(byte) else { return false }
            if numberBytes.count < Self.maxIntegerLiteralByteCount {
                numberBytes.append(byte)
            } else {
                numberOverflowed = true
            }
            return true
        }

        private mutating func finishNumber() {
            guard let numberKey else { return }
            defer {
                self.numberKey = nil
                numberBytes.removeAll(keepingCapacity: true)
                numberOverflowed = false
                currentKey = nil
            }
            guard !numberOverflowed,
                  let literal = String(bytes: numberBytes, encoding: .utf8),
                  let value = Int(literal) else {
                return
            }
            if numberKey == "revision" {
                header.revision = value
            } else if numberKey == "version" {
                header.version = value
            }
        }

        static let backslash = UInt8(ascii: "\\")
        static let colon = UInt8(ascii: ":")
        static let comma = UInt8(ascii: ",")
        static let leftBrace = UInt8(ascii: "{")
        static let leftBracket = UInt8(ascii: "[")
        static let minus = UInt8(ascii: "-")
        static let quote = UInt8(ascii: "\"")
        static let rightBrace = UInt8(ascii: "}")
        static let rightBracket = UInt8(ascii: "]")
        private static let maxIntegerLiteralByteCount = 20

        private static func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == UInt8(ascii: " ")
                || byte == UInt8(ascii: "\n")
                || byte == UInt8(ascii: "\r")
                || byte == UInt8(ascii: "\t")
        }
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
        var scanner = TopLevelSnapshotHeaderScanner()
        scanner.consume(prefixData)
        var header = scanner.header
        guard !header.isComplete,
              fileSize > UInt64(Self.oversizedSnapshotHeaderChunkByteCount) else {
            return header
        }

        let tailOffset = fileSize - UInt64(Self.oversizedSnapshotHeaderChunkByteCount)
        try handle.seek(toOffset: tailOffset)
        let tailData = try handle.read(
            upToCount: Self.oversizedSnapshotHeaderChunkByteCount
        ) ?? Data()
        let tailHeader = Self.topLevelTailSnapshotHeader(in: tailData)
        header.version = header.version ?? tailHeader.version
        header.revision = header.revision ?? tailHeader.revision
        return header
    }

    private static func topLevelTailSnapshotHeader(in data: Data) -> SnapshotHeader {
        guard let suffixStart = topLevelTailSuffixStart(in: data) else {
            return SnapshotHeader()
        }
        var scanner = TopLevelSnapshotHeaderScanner()
        scanner.consume(Data("{".utf8))
        scanner.consume(Data(data[suffixStart..<data.endIndex]))
        return scanner.header
    }

    private static func topLevelTailSuffixStart(in data: Data) -> Data.Index? {
        var isInString = false
        var depth = 0
        var index = data.endIndex
        while index > data.startIndex {
            index = data.index(before: index)
            let byte = data[index]
            if byte == TopLevelSnapshotHeaderScanner.quote,
               !isEscapedQuote(at: index, in: data) {
                isInString.toggle()
                continue
            }
            guard !isInString else { continue }
            if byte == TopLevelSnapshotHeaderScanner.rightBracket, depth == 1 {
                var suffixStart = data.index(after: index)
                while suffixStart < data.endIndex,
                      TopLevelSnapshotHeaderScanner.isWhitespace(data[suffixStart]) {
                    suffixStart = data.index(after: suffixStart)
                }
                if suffixStart < data.endIndex,
                   data[suffixStart] == TopLevelSnapshotHeaderScanner.comma {
                    suffixStart = data.index(after: suffixStart)
                }
                return suffixStart
            }
            switch byte {
            case TopLevelSnapshotHeaderScanner.rightBrace, TopLevelSnapshotHeaderScanner.rightBracket:
                depth += 1
            case TopLevelSnapshotHeaderScanner.leftBrace, TopLevelSnapshotHeaderScanner.leftBracket:
                depth = max(0, depth - 1)
            default:
                break
            }
        }
        return nil
    }

    private static func isEscapedQuote(at index: Data.Index, in data: Data) -> Bool {
        var backslashCount = 0
        var cursor = index
        while cursor > data.startIndex {
            let previous = data.index(before: cursor)
            guard data[previous] == TopLevelSnapshotHeaderScanner.backslash else {
                break
            }
            backslashCount += 1
            cursor = previous
        }
        return !backslashCount.isMultiple(of: 2)
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
            let backupURL = quarantineBackupURL(for: fileURL)
            pruneQuarantineBackups(for: fileURL, keeping: nil)
            try fileManager.moveItem(at: fileURL, to: backupURL)
            do {
                try fileManager.moveItem(at: replacementURL, to: fileURL)
            } catch {
                restoreQuarantineBackup(backupURL, to: fileURL)
                throw error
            }
            pruneQuarantineBackups(for: fileURL, keeping: backupURL)
            notificationFeedPersistenceLogger.notice(
                "Notification feed oversized file replaced file=\(fileURL.path, privacy: .private) backup=\(backupURL.lastPathComponent, privacy: .private) revision=\(snapshot.revision, privacy: .public)"
            )
        } catch {
            try? fileManager.removeItem(at: replacementURL)
            notificationFeedPersistenceLogger.error(
                "Notification feed oversized file replacement failed file=\(fileURL.path, privacy: .private) revision=\(snapshot.revision, privacy: .public) error=\(error.localizedDescription, privacy: .private)"
            )
            throw error
        }
    }

    private func quarantineBackupURL(for fileURL: URL) -> URL {
        fileURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(fileURL.lastPathComponent).oversized-latest.quarantine",
                isDirectory: false
            )
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

    private func pruneQuarantineBackups(for fileURL: URL, keeping keptURL: URL?) {
        guard let backups = try? quarantineBackupURLs(for: fileURL) else { return }
        let keptName = keptURL?.lastPathComponent
        for backup in backups where backup.lastPathComponent != keptName {
            try? fileManager.removeItem(at: backup)
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
            pruneQuarantineBackups(for: fileURL, keeping: nil)
            notificationFeedPersistenceLogger.notice(
                "Notification feed quarantine restored missing canonical file=\(fileURL.path, privacy: .private) backup=\(backupURL.path, privacy: .private)"
            )
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed quarantine restore failed missing canonical file=\(fileURL.path, privacy: .private) backup=\(backupURL.path, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
            )
        }
    }

    private func restoreQuarantineBackup(_ backupURL: URL, to fileURL: URL) {
        guard !fileManager.fileExists(atPath: fileURL.path),
              fileManager.fileExists(atPath: backupURL.path) else {
            return
        }
        do {
            try fileManager.moveItem(at: backupURL, to: fileURL)
            notificationFeedPersistenceLogger.notice(
                "Notification feed quarantine restored after replacement failure source=\(backupURL.path, privacy: .private) destination=\(fileURL.path, privacy: .private)"
            )
        } catch {
            notificationFeedPersistenceLogger.error(
                "Notification feed quarantine restore failed source=\(backupURL.path, privacy: .private) destination=\(fileURL.path, privacy: .private) error=\(error.localizedDescription, privacy: .private)"
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
            pruneQuarantineBackups(for: fileURL, keeping: nil)
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
            snapshot.notifications.map { $0.boundedForHistory() },
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
        let prefix = Data(#"{"notifications":["#.utf8)
        let separator = Data(",".utf8)
        let suffix = Data(#"],"revision":\#(revision),"version":\#(version)}"#.utf8)
        var data = prefix
        let reserveLimit = Int(min(maxBytes, UInt64(Int.max)))
        data.reserveCapacity(min(
            reserveLimit,
            prefix.count + suffix.count + records.count * 512
        ))
        var retainedRecords: [NotificationFeedHistoryRecord] = []
        retainedRecords.reserveCapacity(records.count)

        for record in records {
            let recordData = try encoder.encode(record)
            let separatorByteCount = retainedRecords.isEmpty ? 0 : separator.count
            let candidateByteCount = data.count + separatorByteCount + recordData.count + suffix.count
            guard UInt64(candidateByteCount) <= maxBytes else { break }
            if !retainedRecords.isEmpty {
                data.append(separator)
            }
            data.append(recordData)
            retainedRecords.append(record)
        }
        data.append(suffix)
        guard UInt64(data.count) <= maxBytes else { return nil }
        return (
            NotificationFeedHistorySnapshot(
                revision: revision,
                notifications: retainedRecords,
                version: version
            ),
            data
        )
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
