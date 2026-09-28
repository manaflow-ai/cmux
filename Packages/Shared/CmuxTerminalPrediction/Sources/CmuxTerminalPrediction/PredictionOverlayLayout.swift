/// Which predicted glyphs fit on the cursor row, and the span of cells the
/// overlay has to cover to draw them.
///
/// Pure cell arithmetic, so it is tested here rather than inside an AppKit
/// view. The host supplies the grid geometry and turns cells into points.
public struct PredictionOverlayLayout: Sendable, Equatable {
    /// The glyphs to draw, each keeping its offset from the live cursor.
    public let glyphs: [PredictedGlyph]
    /// Offset from the cursor of the overlay's first cell. Negative while a
    /// confirmed glyph is held, positive when the first drawn glyph follows
    /// keystrokes that were never shown.
    public let leadingOffset: Int
    /// Offset of the caret marking where typing continues, or `nil` when
    /// that cell is past the right margin.
    public let caretOffset: Int?
    /// Cells from `leadingOffset` through the last glyph or the caret.
    public let cellCount: Int

    /// - Parameters:
    ///   - glyphs: The engine's glyphs, offsets measured from the live cursor.
    ///   - cursorColumn: The cursor's zero-based column on screen.
    ///   - columns: How many columns the grid has.
    /// - Returns: `nil` when nothing should be drawn.
    public init?(glyphs: [PredictedGlyph], cursorColumn: Int, columns: Int) {
        // On the last column the cursor may be waiting to wrap, and nothing
        // exposed here says whether the character under it is already
        // printed. Offsets there could be off by one cell either way, so
        // prediction stops at the margin rather than guess.
        guard columns > 0, cursorColumn >= 0, cursorColumn < columns - 1 else { return nil }

        // Drop what falls off either end of the row: speculative glyphs past
        // the margin will wrap somewhere this does not model, and held
        // confirmations can sit on the row above once the echo wrapped.
        let onRow = glyphs.filter { glyph in
            let column = cursorColumn + glyph.offset
            return column >= 0 && column < columns
        }
        guard let first = onRow.map(\.offset).min(),
              let last = onRow.map(\.offset).max(),
              let lastTyped = glyphs.map(\.offset).max() else { return nil }

        let caret = lastTyped + 1
        // Left of the cursor with nothing speculative, the caret would mark
        // where typing resumes once a pending erase lands, beside the live
        // cursor ghostty already draws. Only a drawn prediction justifies a
        // second one.
        let caretIsAhead = caret >= 0 || glyphs.contains { $0.standing == .speculative }
        let caretOffset = caretIsAhead && cursorColumn + caret < columns ? caret : nil

        self.glyphs = onRow
        self.leadingOffset = first
        self.caretOffset = caretOffset
        self.cellCount = max(last, caretOffset ?? last) - first + 1
    }
}
