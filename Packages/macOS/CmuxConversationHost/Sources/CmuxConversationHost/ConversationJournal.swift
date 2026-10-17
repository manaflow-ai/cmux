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
        var last: ConversationCursor = 0
        if let data = try? Data(contentsOf: journalURL), !data.isEmpty {
            guard data.count <= maximumJournalBytes else { throw ConversationJournalError.fileTooLarge(journalURL.path) }
            let lines = data.split(separator: 10, omittingEmptySubsequences: true)
            for (index, line) in lines.enumerated() {
                do {
                    let event = try decoder.decode(ConversationEvent.self, from: Data(line))
                    guard event.sequence == last + 1 else { throw ConversationJournalError.sequenceMismatch(expected: last + 1, actual: event.sequence) }
                    last = event.sequence
                } catch {
                    // A crash can leave only the final JSON line incomplete. Earlier corruption is fatal.
                    if index == lines.count - 1 { break }
                    if let journalError = error as? ConversationJournalError { throw journalError }
                    throw ConversationJournalError.corruptJournal(journalURL.path)
                }
            }
            try? FileManager.default.setAttributes([.posixPermissions: Int(0o600)], ofItemAtPath: journalURL.path)
        }
        self.lastSequenceValue = last
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
        lastSequenceValue = event.sequence
    }

    /// Returns events strictly after a cursor, bounded by `limit`.
    public func events(after cursor: ConversationCursor, limit: Int = 256) throws -> [ConversationEvent] {
        guard limit > 0 else { return [] }
        guard let data = try? Data(contentsOf: journalURL) else { return [] }
        guard data.count <= maximumJournalBytes else { throw ConversationJournalError.fileTooLarge(journalURL.path) }
        var result: [ConversationEvent] = []
        let lines = data.split(separator: 10, omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            do {
                let event = try decoder.decode(ConversationEvent.self, from: Data(line))
                if event.sequence > cursor { result.append(event); if result.count == limit { break } }
            } catch {
                if index == lines.count - 1 { break }
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
    }

    /// Loads the latest complete snapshot, when one has been written.
    public func loadSnapshot() throws -> ConversationSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL) else { return nil }
        return try decoder.decode(ConversationSnapshot.self, from: data)
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
