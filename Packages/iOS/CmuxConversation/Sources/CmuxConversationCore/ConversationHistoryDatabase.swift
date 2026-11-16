import Foundation
import SQLite3

/// How far back a conversation is stored without gaps: every message with a seq from
/// `oldestSeq` to `newestSeq` is on the device. `complete` once the server said there is
/// nothing older (or a store held the first message).
public struct ConversationHistoryRange: Equatable, Sendable {
    public var oldestSeq: Int
    public var newestSeq: Int
    public var complete: Bool

    public init(oldestSeq: Int, newestSeq: Int, complete: Bool) {
        self.oldestSeq = oldestSeq
        self.newestSeq = newestSeq
        self.complete = complete
    }
}

/// One account's conversation history on this device, in SQLite: every message the phone has
/// read for each conversation (by key, `mac:<id>` or `cloud:<conversation>`), its title and
/// participants, and how far back the history is synced. A message is stored once per
/// conversation (its id is the key), so writing a page again, a retry after an interrupted
/// sync, or a reconnect that reads the same page never duplicates a row.
///
/// Not thread safe: ``ConversationTranscriptCache`` owns each instance and calls it only on its
/// serial queue.
final class ConversationHistoryDatabase {
    typealias SyncedRange = ConversationHistoryRange

    enum Failure: Error, Equatable {
        case open(String)
        case statement(String)
    }

    /// The schema this build writes (`PRAGMA user_version`).
    static let schemaVersion: Int32 = 1

    let url: URL
    private var handle: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL) throws {
        self.url = url
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path(percentEncoded: false), &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw Failure.open(message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
        try migrate()
    }

    deinit { sqlite3_close(handle) }

    private func migrate() throws {
        // Set before the first table exists: trimmed pages go back to the file system.
        try exec("PRAGMA auto_vacuum=INCREMENTAL")
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        let version = try queryInt("PRAGMA user_version") ?? 0
        guard version < Self.schemaVersion else { return }
        try transaction {
            try exec("""
            CREATE TABLE IF NOT EXISTS messages (
                conversation TEXT NOT NULL,
                id TEXT NOT NULL,
                seq INTEGER NOT NULL,
                body BLOB NOT NULL,
                PRIMARY KEY (conversation, id)
            )
            """)
            try exec("CREATE INDEX IF NOT EXISTS messages_by_seq ON messages (conversation, seq)")
            try exec("""
            CREATE TABLE IF NOT EXISTS conversations (
                conversation TEXT PRIMARY KEY,
                info BLOB,
                me_id TEXT,
                oldest_seq INTEGER,
                newest_seq INTEGER,
                complete INTEGER NOT NULL DEFAULT 0,
                written_at REAL NOT NULL DEFAULT 0
            )
            """)
            // Delete for me: the row never comes back, not from a later sync either.
            try exec("""
            CREATE TABLE IF NOT EXISTS deleted (
                conversation TEXT NOT NULL,
                id TEXT NOT NULL,
                PRIMARY KEY (conversation, id)
            )
            """)
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: Reads

    /// The newest `limit` messages of `conversation`, oldest first.
    func newest(_ conversation: String, limit: Int) throws -> [ConversationMessage] {
        try messages("SELECT body FROM messages WHERE conversation = ? ORDER BY seq DESC LIMIT ?",
                     [.text(conversation), .integer(Int64(limit))]).reversed()
    }

    /// Up to `limit` messages older than `beforeSeq`, oldest first.
    func older(_ conversation: String, beforeSeq: Int, limit: Int) throws -> [ConversationMessage] {
        try messages("SELECT body FROM messages WHERE conversation = ? AND seq < ? ORDER BY seq DESC LIMIT ?",
                     [.text(conversation), .integer(Int64(beforeSeq)), .integer(Int64(limit))]).reversed()
    }

    func count(_ conversation: String) throws -> Int {
        try queryInt("SELECT COUNT(*) FROM messages WHERE conversation = ?", [.text(conversation)]) ?? 0
    }

    /// The conversation's title, participants and my participant id, as last stored.
    func info(_ conversation: String) throws -> (info: ConversationInfo?, meID: String?)? {
        let statement = try prepare("SELECT info, me_id FROM conversations WHERE conversation = ?", [.text(conversation)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let info = blob(statement, 0).flatMap { try? decoder.decode(ConversationInfo.self, from: $0) }
        let meID = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(statement, 1))
        return (info, meID)
    }

    func syncedRange(_ conversation: String) throws -> SyncedRange? {
        let statement = try prepare("SELECT oldest_seq, newest_seq, complete FROM conversations WHERE conversation = ?",
                                    [.text(conversation)])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL, sqlite3_column_type(statement, 1) != SQLITE_NULL else { return nil }
        return SyncedRange(oldestSeq: Int(sqlite3_column_int64(statement, 0)), newestSeq: Int(sqlite3_column_int64(statement, 1)),
                           complete: sqlite3_column_int(statement, 2) != 0)
    }

    /// Every conversation with stored history.
    func conversations() throws -> [String] {
        let statement = try prepare("SELECT DISTINCT conversation FROM messages ORDER BY conversation")
        defer { sqlite3_finalize(statement) }
        var keys: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { keys.append(String(cString: sqlite3_column_text(statement, 0))) }
        return keys
    }

    // MARK: Writes

    /// Stores `messages` (acknowledged ones: a seq) and, when given, the conversation's info,
    /// and moves the synced range to `range` (nil leaves it), all in one transaction: an
    /// interrupted write leaves the database as it was.
    func write(_ conversation: String, messages: [ConversationMessage], info: ConversationInfo?? = nil, meID: String?? = nil,
               range: SyncedRange?? = nil, deleting deleted: Set<String> = []) throws {
        try transaction {
            try exec("INSERT OR IGNORE INTO conversations (conversation) VALUES (?)", [.text(conversation)])
            try exec("UPDATE conversations SET written_at = ? WHERE conversation = ?",
                     [.real(Date().timeIntervalSince1970), .text(conversation)])
            if case let .some(info) = info {
                try exec("UPDATE conversations SET info = ? WHERE conversation = ?",
                         [info.flatMap { try? encoder.encode($0) }.map(Value.blob) ?? .null, .text(conversation)])
            }
            if case let .some(meID) = meID {
                try exec("UPDATE conversations SET me_id = ? WHERE conversation = ?", [meID.map(Value.text) ?? .null, .text(conversation)])
            }
            for id in deleted {
                try exec("INSERT OR IGNORE INTO deleted (conversation, id) VALUES (?, ?)", [.text(conversation), .text(id)])
                try exec("DELETE FROM messages WHERE conversation = ? AND id = ?", [.text(conversation), .text(id)])
            }
            let upsert = try prepare("""
            INSERT INTO messages (conversation, id, seq, body)
            SELECT ?1, ?2, ?3, ?4 WHERE NOT EXISTS (SELECT 1 FROM deleted WHERE conversation = ?1 AND id = ?2)
            ON CONFLICT (conversation, id) DO UPDATE SET seq = excluded.seq, body = excluded.body
            """)
            defer { sqlite3_finalize(upsert) }
            for message in messages {
                guard let seq = message.seq, !message.isScheduled else { continue }
                let body = try encoder.encode(Self.stored(message))
                sqlite3_reset(upsert)
                try bind(upsert, [.text(conversation), .text(message.id), .integer(Int64(seq)), .blob(body)])
                guard sqlite3_step(upsert) == SQLITE_DONE else { throw Failure.statement(lastError) }
            }
            if case let .some(range) = range {
                try exec("UPDATE conversations SET oldest_seq = ?, newest_seq = ?, complete = ? WHERE conversation = ?", [
                    range.map { .integer(Int64($0.oldestSeq)) } ?? .null,
                    range.map { .integer(Int64($0.newestSeq)) } ?? .null,
                    .integer(range?.complete == true ? 1 : 0), .text(conversation),
                ])
            }
        }
    }

    /// The server's history no longer holds what is stored (a reset backend): this
    /// conversation's rows and range go; its deleted-for-me marks stay.
    func forget(_ conversation: String) throws {
        try transaction {
            try exec("DELETE FROM messages WHERE conversation = ?", [.text(conversation)])
            // The title and participants stay: they still name the conversation.
            try exec("UPDATE conversations SET oldest_seq = NULL, newest_seq = NULL, complete = 0 WHERE conversation = ?",
                     [.text(conversation)])
        }
    }

    /// Whether any of `ids` is stored for `conversation`.
    func containsAny(_ conversation: String, ids: [String]) throws -> Bool {
        for id in ids where try queryInt("SELECT 1 FROM messages WHERE conversation = ? AND id = ?", [.text(conversation), .text(id)]) != nil {
            return true
        }
        return false
    }

    /// Stores `messages` and widens the synced range by `range` (min, max, either complete),
    /// against the range as it is now, in one transaction: a store's save that widened it
    /// meanwhile is kept.
    func merge(_ conversation: String, messages: [ConversationMessage], range: SyncedRange) throws {
        let merged = try syncedRange(conversation).map {
            SyncedRange(oldestSeq: min($0.oldestSeq, range.oldestSeq), newestSeq: max($0.newestSeq, range.newestSeq),
                        complete: $0.complete || range.complete)
        } ?? range
        try write(conversation, messages: messages, range: .some(merged))
    }

    /// The database's size in bytes (pages in use).
    func byteCount() throws -> Int {
        let pages = try queryInt("PRAGMA page_count") ?? 0
        let free = try queryInt("PRAGMA freelist_count") ?? 0
        let size = try queryInt("PRAGMA page_size") ?? 4096
        return (pages - free) * size
    }

    /// Over `byteLimit`: the conversation written longest ago loses its oldest messages first,
    /// down to its newest `keepingNewest`, then the next, until the rest fit. Each
    /// trimmed conversation's synced range moves up to its oldest kept message and is no longer
    /// complete, so scrolling past it asks the server again. Never trims below `keepingNewest`.
    func trim(to byteLimit: Int, keepingNewest: Int) throws {
        guard try byteCount() > byteLimit else { return }
        let statement = try prepare("SELECT conversation FROM conversations ORDER BY written_at ASC")
        var order: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { order.append(String(cString: sqlite3_column_text(statement, 0))) }
        sqlite3_finalize(statement)
        // The one written longest ago shrinks to its newest `keepingNewest` before the next is
        // touched, half its excess at a time.
        for conversation in order {
            while try byteCount() > byteLimit {
                let excess = try count(conversation) - keepingNewest
                guard excess > 0 else { break }
                try transaction {
                    try exec("""
                    DELETE FROM messages WHERE conversation = ?1 AND id IN
                    (SELECT id FROM messages WHERE conversation = ?1 ORDER BY seq ASC LIMIT ?2)
                    """, [.text(conversation), .integer(Int64(max(1, excess / 2)))])
                    try exec("""
                    UPDATE conversations SET complete = 0,
                    oldest_seq = (SELECT MIN(seq) FROM messages WHERE conversation = ?1)
                    WHERE conversation = ?1 AND oldest_seq IS NOT NULL
                    """, [.text(conversation)])
                }
            }
            guard try byteCount() > byteLimit else { break }
        }
        try exec("PRAGMA incremental_vacuum")
    }

    /// What is stored of a message: no image bytes picked on the phone (the server has them).
    static func stored(_ message: ConversationMessage) -> ConversationMessage {
        var message = message
        for index in message.attachments.indices { message.attachments[index].localData = nil }
        return message
    }

    // MARK: SQLite

    enum Value {
        case text(String)
        case integer(Int64)
        case real(Double)
        case blob(Data)
        case null
    }

    private var lastError: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed" }

    private func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func exec(_ sql: String, _ values: [Value] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw Failure.statement("\(lastError): \(sql)") }
    }

    private func queryInt(_ sql: String, _ values: [Value] = []) throws -> Int? {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func messages(_ sql: String, _ values: [Value]) throws -> [ConversationMessage] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [ConversationMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            // A row an older build wrote in a shape this one can't read is skipped, not fatal.
            if let data = blob(statement, 0), let message = try? decoder.decode(ConversationMessage.self, from: data) {
                rows.append(message)
            }
        }
        return rows
    }

    private func blob(_ statement: OpaquePointer?, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func prepare(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.statement("\(lastError): \(sql)")
        }
        do {
            try bind(statement, values)
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ values: [Value]) throws {
        // SQLite copies bound text and blobs (`SQLITE_TRANSIENT`).
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .text(text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case let .integer(number): result = sqlite3_bind_int64(statement, index, number)
            case let .real(number): result = sqlite3_bind_double(statement, index, number)
            case let .blob(data):
                result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw Failure.statement(lastError) }
        }
    }
}
