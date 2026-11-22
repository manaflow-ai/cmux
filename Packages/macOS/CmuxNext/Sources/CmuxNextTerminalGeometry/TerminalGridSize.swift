/// Terminal grid in cells.
public nonisolated struct TerminalGridSize: Sendable, Hashable {
    public var columns: Int
    public var rows: Int
    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }
}
