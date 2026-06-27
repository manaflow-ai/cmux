import SQLite3

/// A thin value wrapper over a prepared `sqlite3_stmt` handle that bridges
/// column values out of the SQLite C API as Swift `String`s.
public struct SQLitePreparedStatement {
    /// The underlying `sqlite3_stmt` pointer.
    public let handle: OpaquePointer

    /// Wraps a prepared-statement handle returned by `sqlite3_prepare_v2`.
    public init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    /// Returns the text of the column at `index`, or `nil` when the column is `NULL`.
    public func text(atColumn index: Int32) -> String? {
        guard let cString = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: cString)
    }
}
