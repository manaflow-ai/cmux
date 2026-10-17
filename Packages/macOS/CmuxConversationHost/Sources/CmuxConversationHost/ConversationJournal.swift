public import Foundation
public import CmuxConversation

/// Crash-safe append-only storage for one conversation's ordered events and snapshot.
public actor ConversationJournal {
    private let directory: URL
    private let journalURL: URL
    private let snapshotURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumJournalBytes = 64 * 1_024 * 1_024
    private var lastSequenceValue: ConversationCursor
    private struct EventOffset: Sendable {
        let offset: UInt64
        let length: Int
    }
    private var eventOffsets: [EventOffset]

    /// Creates or opens a journal directory.
    /// - Parameter directory: Private directory for one session.
    /// - Throws: If the directory cannot be created or existing records are malformed.
    public init(directory: URL) throws {
        self.directory = directory
        self.journalURL = directory.appendingPathComponent("events.jsonl")
        self.snapshotURL = directory.appendingPathComponent("snapshot.json")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: Int(0o700)])
        try? FileManager.default.setAttributes([.posixPermissions: Int(0o700)], ofItemAtPath: directory.path)
        self.eventOffsets = []
        var last: ConversationCursor = 0
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path) }
            catch { throw ConversationJournalError.corruptJournal(journalURL.path) }
            let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard fileSize <= maximumJournalBytes else { throw ConversationJournalError.fileTooLarge(journalURL.path) }
            let data: Data
            do { data = try Data(contentsOf: journalURL) }
            catch { throw ConversationJournalError.corruptJournal(journalURL.path) }
            guard !data.isEmpty else {
                try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: journalURL.path)
                self.lastSequenceValue = 0
                return
            }
            guard data.count <= maximumJournalBytes else { throw ConversationJournalError.fileTooLarge(journalURL.path) }
            let validation = try Self.validate(data: data, decoder: decoder, path: journalURL.path)
            last = validation.lastSequence
            self.eventOffsets = validation.offsets
            if validation.truncateOffset != nil || validation.appendTerminator {
                let handle = try FileHandle(forWritingTo: journalURL)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(validation.truncateOffset ?? data.count))
                if validation.appendTerminator {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data([10]))
                }
                try handle.synchronize()
            }
            try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: journalURL.path)
        }
        self.lastSequenceValue = last
    }

    private struct Validation {
        let lastSequence: ConversationCursor
        let truncateOffset: Int?
        let appendTerminator: Bool
        let offsets: [EventOffset]
    }

    /// Validates every complete line and recovers only a malformed, unterminated final tail.
    /// A complete JSON record without a newline is accepted and terminated before the next append.
    private static func validate(data: Data, decoder: JSONDecoder, path: String) throws -> Validation {
        let bytes = Array(data)
        var start = 0
        var lastSequence: ConversationCursor = 0
        var lastGoodOffset = 0
        var appendTerminator = false
        var offsets: [EventOffset] = []
        while start < bytes.count {
            let newline = bytes[start...].firstIndex(of: 10)
            let end = newline ?? bytes.count
            let line = Data(bytes[start..<end])
            guard !line.isEmpty else { throw ConversationJournalError.corruptJournal(path) }
            do {
                let event = try decoder.decode(ConversationEvent.self, from: line)
                guard event.sequence == lastSequence + 1 else {
                    throw ConversationJournalError.sequenceMismatch(expected: lastSequence + 1, actual: event.sequence)
                }
                lastSequence = event.sequence
                offsets.append(EventOffset(offset: UInt64(start), length: line.count))
            } catch {
                // Only a final line with no newline may be a crash-truncated write.
                if let journalError = error as? ConversationJournalError { throw journalError }
                if newline == nil && end == bytes.count {
                    return Validation(lastSequence: lastSequence, truncateOffset: lastGoodOffset, appendTerminator: false, offsets: offsets)
                }
                throw ConversationJournalError.corruptJournal(path)
            }
            if let newline {
                start = newline + 1
                lastGoodOffset = start
            } else {
                // Keep the complete record, but add the delimiter so future appends remain parseable.
                start = end
                lastGoodOffset = end
                appendTerminator = true
            }
        }
        return Validation(lastSequence: lastSequence, truncateOffset: nil, appendTerminator: appendTerminator, offsets: offsets)
    }

    /// The highest durable event sequence.
    public var lastSequence: ConversationCursor { lastSequenceValue }

    /// Appends one event and synchronizes it to disk before returning.
    /// - Parameter event: Event whose sequence must be exactly the next sequence.
    /// - Throws: If sequence ordering or file I/O fails.
    public func append(_ event: ConversationEvent) throws {
        guard event.sequence == lastSequenceValue + 1 else { throw ConversationJournalError.sequenceMismatch(expected: lastSequenceValue + 1, actual: event.sequence) }
        var data = try encoder.encode(event)
        data.append(10)
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            FileManager.default.createFile(atPath: journalURL.path, contents: nil, attributes: [.posixPermissions: Int(0o600)])
        }
        let currentSize = (try? FileManager.default.attributesOfItem(atPath: journalURL.path)[.size] as? Int) ?? 0
        guard currentSize + data.count <= maximumJournalBytes else { throw ConversationJournalError.fileTooLarge(journalURL.path) }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        eventOffsets.append(EventOffset(offset: UInt64(currentSize), length: data.count - 1))
        lastSequenceValue = event.sequence
    }

    /// Returns events strictly after a cursor, bounded by `limit`.
    public func events(after cursor: ConversationCursor, limit: Int = 256) throws -> [ConversationEvent] {
        guard limit > 0 else { return [] }
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path) }
        catch { throw ConversationJournalError.corruptJournal(journalURL.path) }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maximumJournalBytes else { throw ConversationJournalError.fileTooLarge(journalURL.path) }
        guard cursor < ConversationCursor(eventOffsets.count) else { return [] }
        let startIndex = Int(cursor)
        let endIndex = min(eventOffsets.count, startIndex + limit)
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: journalURL) }
        catch { throw ConversationJournalError.corruptJournal(journalURL.path) }
        defer { try? handle.close() }
        var result: [ConversationEvent] = []
        for index in startIndex..<endIndex {
            let entry = eventOffsets[index]
            do {
                try handle.seek(toOffset: entry.offset)
                guard let data = try handle.read(upToCount: entry.length), data.count == entry.length else {
                    throw ConversationJournalError.corruptJournal(journalURL.path)
                }
                result.append(try decoder.decode(ConversationEvent.self, from: data))
            } catch let error as ConversationJournalError {
                throw error
            } catch {
                throw ConversationJournalError.corruptJournal(journalURL.path)
            }
        }
        return result
    }

    /// Writes a complete snapshot atomically after event data is durable.
    /// - Parameter snapshot: Projection represented by its cursor.
    public func write(snapshot: ConversationSnapshot) throws {
        guard snapshot.cursor <= lastSequenceValue else { throw ConversationJournalError.snapshotAhead(snapshot.cursor, lastSequenceValue) }
        let data = try encoder.encode(snapshot)
        let tempURL = snapshotURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: tempURL.path)
        if FileManager.default.fileExists(atPath: snapshotURL.path) { _ = try FileManager.default.replaceItemAt(snapshotURL, withItemAt: tempURL) }
        else { try FileManager.default.moveItem(at: tempURL, to: snapshotURL) }
        try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: snapshotURL.path)
    }

    /// Loads the latest complete snapshot, when one has been written.
    public func loadSnapshot() throws -> ConversationSnapshot? {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: snapshotURL) }
        catch { throw ConversationJournalError.corruptJournal(snapshotURL.path) }
        do { return try decoder.decode(ConversationSnapshot.self, from: data) }
        catch { throw ConversationJournalError.corruptJournal(snapshotURL.path) }
    }
}

/// Errors protecting ordered journal and snapshot invariants.
public enum ConversationJournalError: Error, Codable, Hashable, Sendable, CustomStringConvertible {
    /// Appended event sequence was not the next sequence.
    case sequenceMismatch(expected: ConversationCursor, actual: ConversationCursor)
    /// Snapshot cursor exceeds durable journal.
    case snapshotAhead(ConversationCursor, ConversationCursor)
    /// A session record could not be decoded.
    case corruptSession(String)
    /// Journal data is corrupted before its final record.
    case corruptJournal(String)
    /// Journal data exceeds the durability bound.
    case fileTooLarge(String)

    public var description: String {
        switch self { case .sequenceMismatch(let expected, let actual): "expected sequence \(expected), got \(actual)"; case .snapshotAhead(let snapshot, let journal): "snapshot \(snapshot) is ahead of journal \(journal)"; case .corruptSession(let value): "corrupt session: \(value)"; case .corruptJournal(let value): "corrupt journal: \(value)"; case .fileTooLarge(let value): "journal too large: \(value)" }
    }
}
