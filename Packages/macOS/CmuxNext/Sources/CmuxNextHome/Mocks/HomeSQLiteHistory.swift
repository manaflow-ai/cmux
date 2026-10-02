public import Foundation
import SQLite3

/// Read-only history over a MessagesLab generated database
/// (`messages(seq, id, sent_at, json)`, `meta`, `participants`; seq 0-based
/// there, 1-based here), for the 1M-message bench. Pages are read and
/// decoded on the reader actor, never on the main thread.
public nonisolated struct HomeSQLiteHistory: HomeMockHistory {
    public let count: Int
    public let title: String
    public let participants: [HomeParticipant]
    private let reader: Reader

    /// Opens `path` read-only; nil when it is not such a database.
    public init?(path: String) {
        guard let reader = Reader(path: path) else { return nil }
        self.reader = reader
        count = reader.count
        title = reader.title
        participants = reader.participants
    }

    public func messages(in range: Range<Int>) async -> [HomeMessage] {
        await reader.page(range.lowerBound - 1..<range.upperBound - 1)
    }

    actor Reader {
        private let handle: Handle
        nonisolated let count: Int
        nonisolated let title: String
        nonisolated let participants: [HomeParticipant]
        private let dates = ISO8601DateFormatter()

        init?(path: String) {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(handle)
                return nil
            }
            func scalar(_ sql: String) -> String? {
                var st: OpaquePointer?
                defer { sqlite3_finalize(st) }
                guard sqlite3_prepare_v2(handle, sql, -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW,
                      let text = sqlite3_column_text(st, 0) else { return nil }
                return String(cString: text)
            }
            count = Int(scalar("SELECT value FROM meta WHERE key='count'") ?? "") ?? 0
            title = scalar("SELECT value FROM meta WHERE key='title'") ?? ""
            var people: [HomeParticipant] = []
            var st: OpaquePointer?
            if sqlite3_prepare_v2(handle, "SELECT json FROM participants", -1, &st, nil) == SQLITE_OK {
                while sqlite3_step(st) == SQLITE_ROW, let text = sqlite3_column_text(st, 0) {
                    guard let object = try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))
                        as? [String: Any], let id = object["id"] as? String else { continue }
                    people.append(HomeParticipant(id: id, displayName: object["displayName"] as? String ?? id,
                                                  isMe: object["isMe"] as? Bool ?? false, isAgent: !(object["isMe"] as? Bool ?? false)))
                }
            }
            sqlite3_finalize(st)
            participants = people
            var statement: OpaquePointer?
            sqlite3_prepare_v2(handle, "SELECT json FROM messages WHERE seq >= ? AND seq < ? ORDER BY seq", -1, &statement, nil)
            self.handle = Handle(db: handle, statement: statement)
            dates.formatOptions = [.withInternetDateTime]
        }


        /// Database rows `range` (0-based seq), decoded.
        func page(_ range: Range<Int>) -> [HomeMessage] {
            guard let statement = handle.statement, !range.isEmpty else { return [] }
            var out: [HomeMessage] = []
            out.reserveCapacity(range.count)
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, Int64(range.lowerBound))
            sqlite3_bind_int64(statement, 2, Int64(range.upperBound))
            var seq = range.lowerBound
            while sqlite3_step(statement) == SQLITE_ROW {
                seq += 1
                let length = Int(sqlite3_column_bytes(statement, 0))
                guard let bytes = sqlite3_column_blob(statement, 0),
                      let object = try? JSONSerialization.jsonObject(with: Data(bytes: bytes, count: length)) as? [String: Any],
                      let message = HomeSQLiteDecoding.message(object, seq: seq, dates: dates) else { continue }
                out.append(message)
            }
            return out
        }
    }

    /// The connection and its page statement; closed with the reader. Used
    /// only from the reader actor.
    nonisolated final class Handle: @unchecked Sendable {
        let db: OpaquePointer?
        let statement: OpaquePointer?

        init(db: OpaquePointer?, statement: OpaquePointer?) {
            self.db = db
            self.statement = statement
        }

        deinit {
            sqlite3_finalize(statement)
            sqlite3_close(db)
        }
    }
}
