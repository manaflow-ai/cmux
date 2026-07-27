/// One absolute terminal cell in a characterwise Vim Mode selection.
public struct TerminalKeyboardCopyModeVisualSelectionCell: Equatable, Sendable {
    /// The absolute screen row.
    public var screenRow: UInt64
    /// The zero-based terminal column.
    public var column: Int

    /// Creates an absolute terminal cell.
    public init(screenRow: UInt64, column: Int) {
        self.screenRow = screenRow
        self.column = column
    }
}
