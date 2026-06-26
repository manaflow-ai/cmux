import Foundation
import SQLite3

/// Row-decoding helpers for ``CmuxSyncStore``. These read column values from an
/// already-stepped statement and encode payload bytes; they do NOT touch the raw
/// SQLite handle (that stays private to ``SyncDatabase``), so keeping them in an
/// extension here does not widen any concurrency-sensitive state. Defensive by
/// design: NULL / invalid-UTF-8 text columns fall back to safe defaults so a
/// corrupt or hostile row never crashes the read path.
extension CmuxSyncStore {
    func readRecord(_ statement: OpaquePointer?, teamID: String, collection: String) -> StoredSyncRecord {
        let recordID = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let rev = Int(sqlite3_column_int64(statement, 1))
        let updatedAt = sqlite3_column_double(statement, 2)
        let sortKey = sqlite3_column_double(statement, 3)
        let deleted = sqlite3_column_int(statement, 4) != 0
        let payload = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? "{}"
        return StoredSyncRecord(
            collection: collection,
            recordID: recordID,
            rev: rev,
            updatedAt: updatedAt,
            sortKey: sortKey,
            deleted: deleted,
            payloadJSON: Data(payload.utf8)
        )
    }

    func jsonString(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? "{}"
    }
}
