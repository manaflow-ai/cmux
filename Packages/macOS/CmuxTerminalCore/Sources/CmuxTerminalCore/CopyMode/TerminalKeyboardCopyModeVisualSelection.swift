/// A characterwise Vim Mode selection tracked in absolute terminal cells.
///
/// The selection remains stable while the viewport scrolls. The terminal host
/// projects its visible segments into an overlay and reads the same absolute
/// range when the user copies.
public struct TerminalKeyboardCopyModeVisualSelection: Equatable, Sendable {
    /// An absolute terminal cell.
    public struct Cell: Equatable, Sendable {
        public var screenRow: UInt64
        public var column: Int

        public init(screenRow: UInt64, column: Int) {
            self.screenRow = screenRow
            self.column = column
        }
    }

    /// A selected row segment expressed in viewport coordinates.
    public struct VisibleSegment: Equatable, Sendable {
        public let viewportRow: Int
        public let startColumn: Int
        public let endColumn: Int

        public init(viewportRow: Int, startColumn: Int, endColumn: Int) {
            self.viewportRow = viewportRow
            self.startColumn = startColumn
            self.endColumn = endColumn
        }
    }

    public var anchor: Cell
    public var endpoint: Cell

    public init(anchor: Cell, endpoint: Cell) {
        self.anchor = anchor
        self.endpoint = endpoint
    }

    /// The selected cells in terminal reading order.
    public var normalizedCells: (start: Cell, end: Cell) {
        Self.precedes(anchor, endpoint) ? (anchor, endpoint) : (endpoint, anchor)
    }

    /// The absolute rows touched by the selection.
    public var selectedRows: ClosedRange<UInt64> {
        let cells = normalizedCells
        return cells.start.screenRow ... cells.end.screenRow
    }

    /// Returns selected row segments intersecting the visible viewport.
    public func visibleSegments(
        scrollOffset: UInt64,
        viewportRows: Int,
        viewportColumns: Int
    ) -> [VisibleSegment] {
        let columns = max(viewportColumns, 1)
        let visibleRows = TerminalKeyboardCopyModeVisualLineSelection.visibleScreenRows(
            scrollOffset: scrollOffset,
            viewportRows: viewportRows
        )
        let cells = normalizedCells
        let firstVisibleRow = max(cells.start.screenRow, visibleRows.lowerBound)
        let lastVisibleRow = min(cells.end.screenRow, visibleRows.upperBound)
        guard firstVisibleRow <= lastVisibleRow else { return [] }

        var segments: [VisibleSegment] = []
        segments.reserveCapacity(Int(clamping: lastVisibleRow - firstVisibleRow + 1))
        for screenRow in firstVisibleRow ... lastVisibleRow {
            let startColumn = screenRow == cells.start.screenRow
                ? Self.clamp(cells.start.column, columns: columns)
                : 0
            let endColumn = screenRow == cells.end.screenRow
                ? Self.clamp(cells.end.column, columns: columns)
                : columns - 1
            segments.append(VisibleSegment(
                viewportRow: Int(clamping: screenRow - scrollOffset),
                startColumn: startColumn,
                endColumn: max(startColumn, endColumn)
            ))
        }
        return segments
    }

    /// Moves the selection endpoint and reports any required viewport scroll.
    public mutating func moveEndpoint(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        viewportRows: Int,
        viewportColumns: Int,
        scrollOffset: UInt64,
        totalRows: UInt64?
    ) -> (cursor: TerminalKeyboardCopyModeCursor, scrollDelta: Int) {
        let rows = max(viewportRows, 1)
        let columns = max(viewportColumns, 1)
        let clampedCount = terminalKeyboardCopyModeClampCount(count)
        let visibleRows = TerminalKeyboardCopyModeVisualLineSelection.visibleScreenRows(
            scrollOffset: scrollOffset,
            viewportRows: rows
        )
        let wasEndpointVisible = visibleRows.contains(endpoint.screenRow)

        switch direction {
        case .left:
            endpoint.column = max(0, endpoint.column - clampedCount)
        case .right:
            endpoint.column = min(columns - 1, endpoint.column + clampedCount)
        case .beginningOfLine:
            endpoint.column = 0
        case .endOfLine:
            endpoint.column = columns - 1
        case .up:
            offsetEndpointRow(delta: -clampedCount, totalRows: totalRows)
        case .down:
            offsetEndpointRow(delta: clampedCount, totalRows: totalRows)
        case .pageUp:
            offsetEndpointRow(delta: -(rows * clampedCount), totalRows: totalRows)
        case .pageDown:
            offsetEndpointRow(delta: rows * clampedCount, totalRows: totalRows)
        case .home:
            endpoint = Cell(screenRow: 0, column: 0)
        case .end:
            endpoint = Cell(
                screenRow: totalRows.map { $0 > 0 ? $0 - 1 : 0 } ?? 0,
                column: columns - 1
            )
        }

        let scrollDelta: Int
        if !wasEndpointVisible {
            scrollDelta = 0
        } else if endpoint.screenRow < visibleRows.lowerBound {
            scrollDelta = -Int(clamping: visibleRows.lowerBound - endpoint.screenRow)
        } else if endpoint.screenRow > visibleRows.upperBound {
            scrollDelta = Int(clamping: endpoint.screenRow - visibleRows.upperBound)
        } else {
            scrollDelta = 0
        }
        let projectedOffset = scrollDelta == 0
            ? scrollOffset
            : TerminalKeyboardCopyModeVisualLineSelection.pendingScrollOffset(
                baseOffset: scrollOffset,
                lineDelta: scrollDelta,
                totalRows: totalRows
            )
        return (
            cursor: endpointCursor(
                scrollOffset: projectedOffset,
                viewportRows: rows,
                viewportColumns: columns
            ),
            scrollDelta: scrollDelta
        )
    }

    /// Projects the endpoint into the current viewport.
    public func endpointCursor(
        scrollOffset: UInt64,
        viewportRows: Int,
        viewportColumns: Int
    ) -> TerminalKeyboardCopyModeCursor {
        TerminalKeyboardCopyModeCursor(
            row: TerminalKeyboardCopyModeVisualLineSelection.viewportRow(
                forScreenRow: endpoint.screenRow,
                scrollOffset: scrollOffset,
                viewportRows: viewportRows
            ),
            column: Self.clamp(endpoint.column, columns: viewportColumns)
        )
    }

    private mutating func offsetEndpointRow(delta: Int, totalRows: UInt64?) {
        let magnitude = UInt64(clamping: delta.magnitude)
        let moved: UInt64
        if delta > 0 {
            moved = endpoint.screenRow > UInt64.max - magnitude
                ? UInt64.max
                : endpoint.screenRow + magnitude
        } else {
            moved = endpoint.screenRow > magnitude ? endpoint.screenRow - magnitude : 0
        }
        endpoint.screenRow = totalRows.flatMap { $0 > 0 ? min(moved, $0 - 1) : 0 } ?? moved
    }

    private static func precedes(_ lhs: Cell, _ rhs: Cell) -> Bool {
        lhs.screenRow < rhs.screenRow
            || (lhs.screenRow == rhs.screenRow && lhs.column <= rhs.column)
    }

    private static func clamp(_ column: Int, columns: Int) -> Int {
        max(0, min(max(columns, 1) - 1, column))
    }
}
