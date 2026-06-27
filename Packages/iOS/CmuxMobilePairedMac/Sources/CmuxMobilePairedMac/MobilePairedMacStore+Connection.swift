import SQLite3

extension MobilePairedMacStore {
    /// Open the SQLite connection and set connection pragmas. `nonisolated`
    /// `static` so the actor's synchronous initializer can build the handle
    /// without hopping isolation. Opened with `SQLITE_OPEN_FULLMUTEX` so SQLite
    /// serializes access internally; the actor adds an outer serialization layer.
    /// Schema migration runs lazily on first store access via `ensureReady()`.
    nonisolated static func openConnection(path: String) throws -> OpaquePointer {
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
