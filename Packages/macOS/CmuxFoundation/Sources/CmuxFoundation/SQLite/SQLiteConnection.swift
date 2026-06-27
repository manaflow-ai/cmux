import SQLite3

/// A thin value wrapper over a `sqlite3` database handle that surfaces the
/// connection's most recent error message from the SQLite C API.
public struct SQLiteConnection {
    /// The underlying `sqlite3` pointer, `nil` when the handle was never opened.
    public let handle: OpaquePointer?

    /// Wraps a database handle from `sqlite3_open_v2` (or `nil`).
    public init(_ handle: OpaquePointer?) {
        self.handle = handle
    }

    /// The latest error message for the connection, or `nil` when the handle is
    /// `nil` or SQLite reports no message.
    public var errorMessage: String? {
        guard let handle, let cString = sqlite3_errmsg(handle) else { return nil }
        return String(cString: cString)
    }
}
