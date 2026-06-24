import SQLite3

/// C-string bridges over the SQLite3 statement/database handles that callers
/// hold as `OpaquePointer`. SQLite hands back UTF-8 `const char *` values for
/// column text and error messages; these accessors decode them into Swift
/// `String?`, returning `nil` when the underlying C call returns `NULL`.
extension OpaquePointer {
    /// The UTF-8 text of the column at `index` in the current row of this
    /// prepared statement, or `nil` when the column is `NULL`.
    ///
    /// `self` is the `sqlite3_stmt *` returned by `sqlite3_prepare_v2`.
    public func sqliteColumnText(_ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(self, index) else { return nil }
        return String(cString: cString)
    }

    /// The most recent error message for this database connection, or `nil`
    /// when SQLite has no message to report.
    ///
    /// `self` is the `sqlite3 *` returned by `sqlite3_open_v2`.
    public var sqliteErrorMessage: String? {
        guard let cString = sqlite3_errmsg(self) else { return nil }
        return String(cString: cString)
    }
}
