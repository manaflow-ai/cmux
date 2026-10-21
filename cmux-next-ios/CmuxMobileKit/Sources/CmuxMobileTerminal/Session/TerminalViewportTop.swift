import CoreGraphics

/// Ghostty's viewport top in the scrollbar's numbering, for turning the
/// cursor's viewport row into an absolute row (termqa N3).
///
/// A `scroll_to_row` at or below the active area's top does not pin a row:
/// Ghostty makes the viewport follow the active area (`PageList.scroll`,
/// `.row`), so it moves down with every row that arrives after the request.
/// The last request is Ghostty's viewport only until a report comes in; after
/// that the report is. Reading the cursor against an older request put it
/// rows above where it is drawn, and a last row with no text (a reverse-video
/// bar, an empty `cat` line) fell out of the document, under the composer.
public struct TerminalViewportTop: Equatable, Sendable {
    /// The last row given to `scroll_to_row`, nil before the first.
    public private(set) var requestedRow: Int?
    /// A scrollbar report arrived after the last request.
    public private(set) var reportedSinceRequest = true

    public init() {}

    /// A `scroll_to_row` for `row` was sent.
    public mutating func request(_ row: Int) {
        requestedRow = row
        reportedSinceRequest = false
    }

    /// A scrollbar report arrived: it shows Ghostty's viewport, including
    /// any following of the active area since the request.
    public mutating func report() {
        reportedSinceRequest = true
    }

    /// Ghostty pruned or renumbered rows: the request moves with them.
    public mutating func shiftRows(by delta: Int) {
        requestedRow = requestedRow.map { max(0, $0 + delta) }
    }

    /// The viewport's top row for a measure with the last report
    /// (`reportedOffset`, `totalRows`) and the grid's rows: the report once
    /// it is newer than the request, else the request (a request inside the
    /// active area is the active area's top).
    public func top(reportedOffset: Int, totalRows: Int, gridRows: Int) -> Int {
        let activeTop = max(0, totalRows - gridRows)
        guard let requestedRow, !reportedSinceRequest else { return min(max(0, reportedOffset), activeTop) }
        return min(requestedRow, activeTop)
    }

    /// The cursor's absolute row for its viewport row `viewportRow`.
    public func cursorRow(viewportRow: Int, reportedOffset: Int, totalRows: Int, gridRows: Int) -> Int {
        top(reportedOffset: reportedOffset, totalRows: totalRows, gridRows: gridRows) + viewportRow
    }
}

extension TerminalDocumentLayout {
    /// The pin log's gap between what is drawn last and the composer card's
    /// top (page points): the lower of the document's last row and the
    /// drawn cursor row (nil: the cursor is not in the frame). Negative: the
    /// drawn row is under the card.
    public static func drawnGap(composerTop: CGFloat, lastRowBottom: CGFloat, cursorRowBottom: CGFloat?) -> CGFloat {
        composerTop - max(lastRowBottom, cursorRowBottom ?? lastRowBottom)
    }
}
