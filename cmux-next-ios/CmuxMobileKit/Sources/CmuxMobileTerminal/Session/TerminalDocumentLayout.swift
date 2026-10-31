import CoreGraphics

/// Where the terminal's scrollable document starts and ends in Ghostty's
/// absolute rows (0 = the oldest scrollback row), and how its rows map to the
/// scroll view's content coordinates. Portable rules of
/// `TerminalViewController`, unit tested (verify/design/terminal/SPEC.md B1).
///
/// The phone mirrors the Mac's screen at the bottom of a taller local grid
/// (`TerminalRowShift`), so a short session has rows above the Mac's row 0
/// that nothing ever wrote. They are not part of the document: its top is
/// the first row with text (or the cursor's row, if that is higher), so a
/// short session draws row 0 at the top inset like Terminal.app, there is
/// nothing above it to scroll into, and `clear` puts the prompt back at the
/// top. Blank space is only ever below the cursor.
public struct TerminalDocumentLayout: Equatable, Sendable {
    /// First absolute row of the document.
    public var originRow: Int
    /// One past the last absolute row of the document: the cursor's row or
    /// the last row with text below it, whichever is lower (+ 1), or the
    /// scrollback total when the cursor is unknown.
    public var endRow: Int

    public init(originRow: Int, endRow: Int) {
        self.originRow = max(0, originRow)
        self.endRow = max(self.originRow + 1, endRow)
    }

    /// Rows in the document (at least one).
    public var rowCount: Int { endRow - originRow }

    /// The document for Ghostty's scrollback `total`, the cursor's absolute
    /// row (nil: unknown) and the blank rows at the top of the screen (nil:
    /// not read; 0 for a local session with no mirror offset).
    public static func make(totalRows: Int, cursorRow: Int?, leadingBlankRows: Int?,
                            lastContentRow: Int? = nil) -> TerminalDocumentLayout {
        let total = max(1, totalRows)
        // An inline TUI (Codex CLI) keeps the cursor in its input box and
        // draws rows below it (hints, status): they are part of the document,
        // or the last of them would rest under the composer (user report,
        // 2026-10-14).
        let lastRow = max(cursorRow ?? -1, lastContentRow ?? -1)
        let end = lastRow >= 0 ? min(total, lastRow + 1) : total
        var origin = leadingBlankRows ?? 0
        // Never start below the cursor: the prompt row is always in the document.
        if let cursorRow { origin = min(origin, cursorRow) }
        origin = min(origin, end - 1)
        return TerminalDocumentLayout(originRow: origin, endRow: end)
    }

    /// The document while a finger or a deceleration owns the page: the new
    /// rows (`totalRows` grew from `previousTotal`) are added at the end and
    /// nothing is read from the screen (a read takes Ghostty's terminal lock,
    /// which a parse holds). The page is measured again when the gesture ends.
    public func grown(fromTotal previousTotal: Int, toTotal totalRows: Int) -> TerminalDocumentLayout {
        let added = max(0, totalRows - previousTotal)
        return TerminalDocumentLayout(originRow: originRow, endRow: min(max(totalRows, endRow), endRow + added))
    }

    /// Content y of absolute `row`'s top edge.
    public func contentY(ofRow row: Int, cellHeight: CGFloat) -> CGFloat {
        CGFloat(row - originRow) * cellHeight
    }

    /// Absolute row at content y (rows above the origin clamp to it).
    public func row(atContentY y: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return originRow }
        return originRow + Int(floor(max(0, y) / cellHeight))
    }

    /// Content height of the document.
    public func contentHeight(cellHeight: CGFloat) -> CGFloat {
        CGFloat(rowCount) * cellHeight
    }

    /// The offset that shows the document's end: the last row just above the
    /// bottom inset (the composer), or the first row at the top inset when the
    /// document is shorter than the space between them (a short session never
    /// floats to the bottom; it moves up only as far as the cursor needs).
    public static func bottomOffset(contentHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat,
                                    bottomInset: CGFloat) -> CGFloat {
        max(-topInset, contentHeight + bottomInset - viewportHeight)
    }

    /// Space between the document's last row and the composer card's top:
    /// none. The last row rests on the card (user report 2026-10-14: with
    /// 8 pt the bottom read as pinned to the row above the composer).
    public static let composerGap: CGFloat = 0

    /// The scroll view's bottom inset for a page `pageHeight` tall whose
    /// composer card starts at `composerTop` (page coordinates): at the
    /// bottom offset, the last row's bottom edge is the card's top.
    public static func bottomInset(pageHeight: CGFloat, composerTop: CGFloat) -> CGFloat {
        max(0, pageHeight - composerTop) + composerGap
    }

    /// Whether the blank rows at the top must be read again: the origin is
    /// unknown, the scrollback shrank (`clear`, a reset), or the document's
    /// top is still on the active screen (where an erase can blank it).
    /// Once the top is in the scrollback above the screen it cannot change
    /// without the total shrinking, so a flood never pays for the read.
    public static func needsOriginScan(previous: TerminalDocumentLayout?, previousTotal: Int, totalRows: Int,
                                       screenRows: Int) -> Bool {
        guard let previous else { return true }
        if totalRows < previousTotal { return true }
        let activeTop = max(0, totalRows - screenRows)
        return previous.originRow >= activeTop
    }

    /// Leading newlines of Ghostty's plain text (one per blank row before
    /// the first row with text), at most `limit`. Text with no newline
    /// before its first character starts at row 0.
    public static func leadingNewlines(in bytes: UnsafeRawBufferPointer, limit: Int) -> Int {
        var count = 0
        for byte in bytes {
            if byte == 0x0A {
                count += 1
                if count >= limit { return limit }
            } else if byte == 0x0D || byte == 0x20 {
                continue
            } else {
                return count
            }
        }
        // Only newlines and spaces: everything read is blank.
        return limit
    }
}

/// Keeps the document's end from moving up while the active screen is the
/// same (termqa D2). An inline TUI (Codex CLI) erases its live area below
/// the cursor and draws it again a moment later; measured as "the last row
/// with text", the end moved up rows and back, and a following page jumped
/// down 7 rows and up again. A terminal's screen rows never go away: once a
/// row near the bottom held text, the document keeps it, blank or not.
///
/// Held as the gap from the scrollback's end (absolute rows shift when
/// Ghostty trims old pages). It is dropped (the end may move up again) by a
/// screen cleared to its first row (`clear`), a shrunk scrollback (a reset,
/// ESC [3J) and a new document (attach, leaving a TUI).
public struct TerminalEndHold: Equatable, Sendable {
    /// The smallest gap between the document's end and the scrollback's end
    /// seen since the screen was last cleared.
    public private(set) var gapRows: Int?
    private var total = 0
    /// The cursor's last distance from the scrollback's end.
    private var cursorGap: Int?

    public init() {}

    /// The end to use for `layout`, measured with `totalRows` rows in the
    /// scrollback, the cursor at `cursorRow` and the Mac's screen starting at
    /// absolute row `screenTopRow`.
    public mutating func hold(_ layout: TerminalDocumentLayout, totalRows: Int, cursorRow: Int?,
                              screenTopRow: Int) -> TerminalDocumentLayout {
        let newCursorGap = cursorRow.map { totalRows - $0 }
        defer {
            total = totalRows
            if let newCursorGap { cursorGap = newCursorGap }
        }
        // The screen was cleared or redrawn from its top: the cursor is on
        // its first row, or it jumped up by more than half the screen (a
        // prompt with a blank line above it lands on the third row; round 8).
        // An inline TUI's cursor moves a few rows inside its live area.
        let screenRows = max(1, totalRows - screenTopRow)
        let jumpedUp = newCursorGap.map { new in cursorGap.map { new - $0 > screenRows / 2 } ?? false } ?? false
        if totalRows < total || (cursorRow.map { $0 <= screenTopRow } ?? false) || jumpedUp {
            gapRows = nil
        }
        let gap = max(0, totalRows - layout.endRow)
        guard let held = gapRows, gap > held else {
            gapRows = gap
            return layout
        }
        let end = min(totalRows, max(layout.endRow, totalRows - held))
        return TerminalDocumentLayout(originRow: layout.originRow, endRow: end)
    }

    /// A new document (attach, a reset, leaving a TUI): nothing is held.
    public mutating func reset() {
        gapRows = nil
        total = 0
        cursorGap = nil
    }
}

