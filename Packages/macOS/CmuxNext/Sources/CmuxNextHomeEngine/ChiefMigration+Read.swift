import CmuxNextDaemon
import Foundation
import SQLite3

/// Reading an old per-tag Chief, read-only: the store from a copy of its
/// SQLite files (a live daemon keeps writing the original), the memory from
/// its JSON lines, the host's cursor from `host.json`.
extension ChiefMigration {
    /// An old Chief: its memory through the store's export when it has the
    /// SQLite store (`memory.sqlite3`), else its JSONL day files; its host
    /// cursor from the store's state table or `host.json`.
    nonisolated static func readSource(_ old: Old, tool: (any ChiefMemoryTool)? = nil, scratch: URL? = nil) async -> ChiefMigrationSource? {
        let optchat = old.muxHome.appendingPathComponent("optchat", isDirectory: true)
        let database = optchat.appendingPathComponent("memory.sqlite3")
        var textDir = optchat.appendingPathComponent("chat", isDirectory: true)
        var hostConversation: String?
        var loggedSeq: UInt64 = 0
        if FileManager.default.fileExists(atPath: database.path) {
            guard let tool, let scratch else { return nil }
            let exported = scratch.appendingPathComponent("export-\(old.tag)", isDirectory: true)
            do { try await tool.exportText(muxHome: old.muxHome, to: exported) } catch { return nil }
            textDir = exported
            let state = Dictionary((readStoreRows(database, "SELECT key, value FROM state WHERE key LIKE 'host/%'") ?? [])
                .compactMap { row in row.count == 2 ? (row[0], row[1]) : nil }, uniquingKeysWith: { first, _ in first })
            (hostConversation, loggedSeq) = cursor(CursorRequest(state: state, hostJson: nil))
        } else if let data = try? Data(contentsOf: optchat.appendingPathComponent("host.json")) { // concurrency-allow: only ChiefMigration.run (@concurrent) reads sources, off the main actor
            (hostConversation, loggedSeq) = cursor(CursorRequest(state: nil, hostJson: String(decoding: data, as: UTF8.self)))
        }
        let log = readLog(textDir.appendingPathComponent("main", isDirectory: true))
        let store = readStore(old.store)
        guard store != nil || !log.isEmpty else { return nil }
        return ChiefMigrationSource(name: old.tag, muxHome: old.muxHome, conversationID: store?.id, conversationCreatedAt: store?.createdAt,
                                    messages: store?.messages ?? [], log: log, textDir: textDir, loggedSeq: loggedSeq,
                                    hostConversation: hostConversation)
    }

    nonisolated private struct CursorRequest: Encodable {
        let state: [String: String]?
        let hostJson: String?
    }

    /// The old host's cursor (`chief_home.migration_cursor`); none if the rules fail.
    nonisolated private static func cursor(_ request: CursorRequest) -> (String?, UInt64) {
        struct Reply: Decodable { let hostConversation: String?; let loggedSeq: UInt64 }
        guard let reply: Reply = try? ChiefHomeRules().call("migration_cursor", request) else { return (nil, 0) }
        return (reply.hostConversation, reply.loggedSeq)
    }

    /// The memory's lines of every `.jsonl` file in `main`, by `i`
    /// (`chief_home.migration_read_log`); empty if the rules fail.
    nonisolated static func readLog(_ main: URL) -> [ChiefMigrationSource.LogEntry] {
        struct Request: Encodable { let files: [String] }
        struct Reply: Decodable { let entries: [ChiefMigrationSource.LogEntry] }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: main.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
        // concurrency-allow: only ChiefMigration.run (@concurrent) and tests read old logs, off the main actor
        let files = names.compactMap { try? String(contentsOf: main.appendingPathComponent($0), encoding: .utf8) }
        let reply: Reply? = try? ChiefHomeRules().call("migration_read_log", Request(files: files))
        return reply?.entries ?? []
    }

    nonisolated struct StoredChief {
        var id: String
        var createdAt: String
        var messages: [ChiefMigrationSource.Message]
    }

    /// The rows of `sql` over a copy of the database at `path` (with its
    /// -wal and -shm files: a live writer keeps the original), or nil.
    nonisolated static func readStoreRows(_ path: URL, _ sql: String, bind: [String] = []) -> [[String]]? {
        withCopy(of: path) { db in rows(db, sql, bind: bind) }
    }

    nonisolated private static func withCopy<T>(of path: URL, _ body: (OpaquePointer) -> T) -> T? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path.path) else { return nil }
        let scratch = fm.temporaryDirectory.appendingPathComponent("chief-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("c.sqlite3")
        do {
            try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: path.path + suffix) {
                try fm.copyItem(atPath: path.path + suffix, toPath: copy.path + suffix)
            }
        } catch { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        return body(db)
    }

    /// The Chief conversation of a store (the oldest with agent_mux) and its messages.
    nonisolated static func readStore(_ path: URL) -> StoredChief? {
        withCopy(of: path) { db in readChief(db) } ?? nil
    }

    nonisolated private static func readChief(_ db: OpaquePointer) -> StoredChief? {
        struct Conversation: Codable { let id, participantsJson, createdAt: String }
        struct Request: Encodable { let conversations: [Conversation] }
        struct Reply: Decodable { let chief: Conversation? }
        let conversations = rows(db, "SELECT id, participants_json, created_at FROM conversation")
            .filter { $0.count == 3 }.map { Conversation(id: $0[0], participantsJson: $0[1], createdAt: $0[2]) }
        // The oldest conversation with agent_mux (chief_home.migration_pick_chief).
        let reply: Reply? = try? ChiefHomeRules().call("migration_pick_chief", Request(conversations: conversations))
        guard let chief = reply?.chief else { return nil }
        let messages = rows(db, "SELECT message_json FROM message WHERE conversation = ?1 ORDER BY seq", bind: [chief.id]).compactMap { row in
            message(fromJSON: row[0])
        }
        return StoredChief(id: chief.id, createdAt: chief.createdAt, messages: messages)
    }

    /// A stored `message_json` row (`chief_home.migration_message`); nil if the rules fail.
    nonisolated static func message(fromJSON json: String) -> ChiefMigrationSource.Message? {
        struct Request: Encodable { let text: String }
        struct Reply: Decodable { let message: ChiefMigrationSource.Message? }
        let reply: Reply? = try? ChiefHomeRules().call("migration_message", Request(text: json))
        return reply?.message
    }

    nonisolated private static func rows(_ db: OpaquePointer, _ sql: String, bind: [String] = []) -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bind.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
        var out: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
        return out
    }
}
