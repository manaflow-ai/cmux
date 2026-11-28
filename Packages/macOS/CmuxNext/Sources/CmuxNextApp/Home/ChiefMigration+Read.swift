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
            let state = Dictionary(uniqueKeysWithValues: (readStoreRows(database, "SELECT key, value FROM state WHERE key LIKE 'host/%'") ?? [])
                .compactMap { row in row.count == 2 ? (row[0], row[1]) : nil })
            hostConversation = state["host/conversation"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) as? String }
            loggedSeq = state["host/logged_seq"].flatMap { UInt64($0) } ?? 0
        } else if let data = try? Data(contentsOf: optchat.appendingPathComponent("host.json")), // concurrency-allow: only ChiefMigration.run (@concurrent) reads sources, off the main actor
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            hostConversation = state["conversation"] as? String
            loggedSeq = (state["logged_seq"] as? NSNumber)?.uint64Value ?? 0
        }
        let log = readLog(textDir.appendingPathComponent("main", isDirectory: true))
        let store = readStore(old.store)
        guard store != nil || !log.isEmpty else { return nil }
        return ChiefMigrationSource(name: old.tag, muxHome: old.muxHome, conversationID: store?.id, conversationCreatedAt: store?.createdAt,
                                    messages: store?.messages ?? [], log: log, textDir: textDir, loggedSeq: loggedSeq,
                                    hostConversation: hostConversation)
    }

    nonisolated static func readLog(_ main: URL) -> [ChiefMigrationSource.LogEntry] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: main.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
        var entries: [ChiefMigrationSource.LogEntry] = []
        for name in names {
            // concurrency-allow: only ChiefMigration.run (@concurrent) and tests read old logs, off the main actor
            guard let text = try? String(contentsOf: main.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let i = (object["i"] as? NSNumber)?.intValue, let kind = object["kind"] as? String,
                      let body = object["text"] as? String, let date = object["date"] as? String else { continue }
                entries.append(.init(i: i, kind: kind, text: body, date: date))
            }
        }
        return entries.sorted { $0.i < $1.i }
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
        let conversations = rows(db, "SELECT id, participants_json, created_at FROM conversation")
        let chief = conversations
            .filter { $0[1].contains("\"agent_mux\"") }
            .min { ($0[2], $0[0]) < ($1[2], $1[0]) }
        guard let chief else { return nil }
        let messages = rows(db, "SELECT message_json FROM message WHERE conversation = ?1 ORDER BY seq", bind: [chief[0]]).compactMap { row in
            message(fromJSON: row[0])
        }
        return StoredChief(id: chief[0], createdAt: chief[2], messages: messages)
    }

    nonisolated static func message(fromJSON json: String) -> ChiefMigrationSource.Message? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), case .object(let fields) = value,
              case .string(let id)? = fields["id"], case .number(let seq)? = fields["seq"], case .string(let author)? = fields["author"],
              case .string(let key)? = fields["client_msg_id"], case .string(let createdAt)? = fields["created_at"],
              case .array(let parts)? = fields["parts"] else { return nil }
        return .init(id: id, seq: UInt64(seq), author: author, clientMsgID: key, createdAt: createdAt, parts: parts)
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
