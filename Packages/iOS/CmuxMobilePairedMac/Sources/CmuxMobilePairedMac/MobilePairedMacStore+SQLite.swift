import SQLite3

extension MobilePairedMacStore {
    enum BindValue {
        case text(String)
        case int(Int64)
        case real(Double)
        case null
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
}
