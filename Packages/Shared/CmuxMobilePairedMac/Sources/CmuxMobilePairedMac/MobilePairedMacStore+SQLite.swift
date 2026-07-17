import SQLite3

extension MobilePairedMacStore {
    // MARK: - Statement helpers

    enum BindValue {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
    }

    func exec(_ sql: String, binding parameters: [BindValue] = []) throws {
        if parameters.isEmpty {
            let rc = sqlite3_exec(db, sql, nil, nil, nil)
            guard rc == SQLITE_OK else {
                throw MobilePairedMacStoreError.stepFailed(rc, lastErrorMessage())
            }
            return
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard rc == SQLITE_OK else {
            throw MobilePairedMacStoreError.prepareFailed(rc, lastErrorMessage())
        }
        try bind(statement: statement, parameters: parameters)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw MobilePairedMacStoreError.stepFailed(step, lastErrorMessage())
        }
    }

    func bind(statement: OpaquePointer?, parameters: [BindValue]) throws {
        for (index, value) in parameters.enumerated() {
            let pos = Int32(index + 1)
            let rc: Int32
            switch value {
            case .text(let s):
                rc = s.withCString { ptr in
                    // SQLITE_TRANSIENT == -1; sqlite3 needs to copy the buffer.
                    sqlite3_bind_text(statement, pos, ptr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .int(let i):
                rc = sqlite3_bind_int64(statement, pos, i)
            case .real(let d):
                rc = sqlite3_bind_double(statement, pos, d)
            case .null:
                rc = sqlite3_bind_null(statement, pos)
            }
            guard rc == SQLITE_OK else {
                throw MobilePairedMacStoreError.stepFailed(rc, lastErrorMessage())
            }
        }
    }

    func transaction(_ block: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            try block()
            try exec("COMMIT;")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    func lastErrorMessage() -> String {
        guard let cString = sqlite3_errmsg(db) else { return "" }
        return String(cString: cString)
    }
}
