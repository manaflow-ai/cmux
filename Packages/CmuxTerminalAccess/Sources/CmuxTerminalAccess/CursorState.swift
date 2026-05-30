// SPDX-License-Identifier: MIT

/// Cursor position and visibility for a single read.
public struct CursorState: Hashable, Sendable, Codable {
    /// Zero-based row of the cursor within the grid.
    public let row: Int
    /// Zero-based column of the cursor within the grid.
    public let col: Int
    /// Whether the cursor should be displayed (DECTCEM).
    public let visible: Bool
    /// Cursor presentation style.
    public let style: CursorStyle

    /// Creates a snapshot of the cursor state at read time.
    public init(row: Int, col: Int, visible: Bool, style: CursorStyle) {
        self.row = row
        self.col = col
        self.visible = visible
        self.style = style
    }
}
