/// A validated cell viewport requested by one local control-socket client.
///
/// This value describes only the render-grid projection sent to that client.
/// It is deliberately not a PTY size: the live pane and every other client
/// continue to use the terminal's native grid.
public struct LocalTerminalViewport: Equatable, Sendable {
    /// Smallest supported column count.
    public static let minimumColumns = 1
    /// Largest supported column count.
    public static let maximumColumns = 4096
    /// Smallest supported row count.
    public static let minimumRows = 1
    /// Largest supported row count.
    public static let maximumRows = 4096

    /// Requested columns.
    public let columns: Int
    /// Requested rows.
    public let rows: Int

    /// Creates a validated cell viewport.
    ///
    /// - Parameters:
    ///   - columns: Number of columns, from ``minimumColumns`` through
    ///     ``maximumColumns``.
    ///   - rows: Number of rows, from ``minimumRows`` through ``maximumRows``.
    /// - Returns: `nil` when either dimension is outside the supported range.
    public init?(columns: Int, rows: Int) {
        guard (Self.minimumColumns...Self.maximumColumns).contains(columns),
              (Self.minimumRows...Self.maximumRows).contains(rows) else {
            return nil
        }
        self.columns = columns
        self.rows = rows
    }
}
