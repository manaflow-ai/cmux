import SQLite3

struct MobilePairedMacSQLiteConnectionOpener {
    func open(path: String) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw MobilePairedMacStoreError.openFailed(rc)
        }
        for pragma in ["PRAGMA foreign_keys = ON;", "PRAGMA journal_mode = WAL;"] {
            let prc = sqlite3_exec(handle, pragma, nil, nil, nil)
            guard prc == SQLITE_OK else {
                sqlite3_close_v2(handle)
                throw MobilePairedMacStoreError.stepFailed(prc, "")
            }
        }
        return handle
    }
}
