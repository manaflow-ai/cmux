/// Ghostty's authoritative primary-screen scrollback boundary, measured in rows.
public nonisolated struct TerminalScrollBoundary: Equatable, Sendable {
    /// The number of rows in the complete screen plus scrollback buffer.
    public let totalRows: UInt64
    /// The zero-based row at the top of the visible viewport.
    public let viewportOffsetRows: UInt64
    /// The number of rows visible in the viewport.
    public let visibleRows: UInt64

    /// Creates an authoritative scrollback boundary from Ghostty scrollbar values.
    ///
    /// - Parameters:
    ///   - totalRows: The number of rows in the complete buffer.
    ///   - viewportOffsetRows: The row at the top of the viewport.
    ///   - visibleRows: The number of visible rows.
    public init(totalRows: UInt64, viewportOffsetRows: UInt64, visibleRows: UInt64) {
        self.totalRows = totalRows
        self.viewportOffsetRows = viewportOffsetRows
        self.visibleRows = visibleRows
    }
}
