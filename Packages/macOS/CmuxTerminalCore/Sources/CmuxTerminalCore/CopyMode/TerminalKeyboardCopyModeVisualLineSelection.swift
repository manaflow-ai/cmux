/// A linewise visual selection tracked in absolute terminal screen rows.
///
/// The host keeps the canonical selection here and derives viewport-relative
/// cursors only for rendering. That keeps copy ranges stable when the viewport
/// scrolls away from the selection endpoint.
///
/// ```swift
/// var selection = TerminalKeyboardCopyModeVisualLineSelection(
///     anchorScreenRow: 10,
///     endpointScreenRow: 12
/// )
/// let move = selection.moveEndpoint(
///     .down,
///     count: 1,
///     currentColumn: 4,
///     viewportRows: 20,
///     viewportColumns: 80,
///     scrollOffset: 0,
///     totalRows: 100
/// )
/// ```
public struct TerminalKeyboardCopyModeVisualLineSelection: Equatable, Sendable {
    /// The absolute screen row where the linewise selection started.
    public var anchorScreenRow: UInt64

    /// The absolute screen row where the linewise selection currently ends.
    public var endpointScreenRow: UInt64

    /// Creates a linewise visual selection in absolute screen rows.
    ///
    /// - Parameters:
    ///   - anchorScreenRow: The absolute screen row where selection started.
    ///   - endpointScreenRow: The absolute screen row where selection ends.
    public init(anchorScreenRow: UInt64, endpointScreenRow: UInt64) {
        self.anchorScreenRow = anchorScreenRow
        self.endpointScreenRow = endpointScreenRow
    }

    /// The selected absolute screen-row range, independent of selection direction.
    public var selectedRows: ClosedRange<UInt64> {
        min(anchorScreenRow, endpointScreenRow) ... max(anchorScreenRow, endpointScreenRow)
    }

    /// Replaces the selected rows while preserving the selection direction.
    ///
    /// - Parameter selectedRows: The inclusive row range reported by the
    ///   runtime's tracked selection pins.
    public mutating func replaceSelectedRows(_ selectedRows: ClosedRange<UInt64>) {
        if anchorScreenRow <= endpointScreenRow {
            anchorScreenRow = selectedRows.lowerBound
            endpointScreenRow = selectedRows.upperBound
        } else {
            anchorScreenRow = selectedRows.upperBound
            endpointScreenRow = selectedRows.lowerBound
        }
    }

    /// Moves the endpoint to a known scrollback boundary.
    ///
    /// - Parameters:
    ///   - direction: The boundary movement to apply.
    ///   - totalRows: The total known screen-row count, when available.
    /// - Returns: `true` when the endpoint was moved without needing viewport cursor projection.
    @discardableResult
    public mutating func moveEndpointToBoundary(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        totalRows: UInt64?
    ) -> Bool {
        switch direction {
        case .home:
            endpointScreenRow = 0
            return true
        case .end:
            guard let totalRows, totalRows > 0 else { return false }
            endpointScreenRow = totalRows - 1
            return true
        default:
            return false
        }
    }

    /// Updates the endpoint from a viewport cursor and scroll offset.
    ///
    /// - Parameters:
    ///   - cursor: The viewport-relative cursor to convert.
    ///   - viewportRows: The current terminal viewport row count.
    ///   - scrollOffset: The absolute screen row at the top of the viewport.
    ///   - totalRows: The total known screen-row count, when available.
    public mutating func updateEndpoint(
        from cursor: TerminalKeyboardCopyModeCursor,
        viewportRows: Int,
        scrollOffset: UInt64,
        totalRows: UInt64?
    ) {
        endpointScreenRow = Self.screenRow(
            forViewportRow: cursor.row,
            viewportRows: viewportRows,
            scrollOffset: scrollOffset,
            totalRows: totalRows
        )
    }

    /// Moves the endpoint and returns the cursor plus any viewport scroll delta needed.
    ///
    /// Endpoint movement starts from ``endpointScreenRow``, not from a clamped
    /// viewport cursor. If the endpoint is already offscreen, vertical movement
    /// changes the absolute endpoint without forcing a viewport jump.
    ///
    /// - Parameters:
    ///   - direction: The linewise movement to apply.
    ///   - count: The repeat count from keyboard copy mode.
    ///   - currentColumn: The current viewport cursor column.
    ///   - viewportRows: The current terminal viewport row count.
    ///   - viewportColumns: The current terminal viewport column count.
    ///   - scrollOffset: The absolute screen row at the top of the viewport.
    ///   - totalRows: The total known screen-row count, when available.
    /// - Returns: A viewport cursor for rendering and a signed line scroll delta.
    public mutating func moveEndpoint(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        count: Int,
        currentColumn: Int,
        viewportRows: Int,
        viewportColumns: Int,
        scrollOffset: UInt64,
        totalRows: UInt64?
    ) -> (cursor: TerminalKeyboardCopyModeCursor, scrollDelta: Int) {
        let clampedRows = max(viewportRows, 1)
        let clampedColumns = max(viewportColumns, 1)
        let clampedCount = terminalKeyboardCopyModeClampCount(count)
        let visibleRows = Self.visibleScreenRows(scrollOffset: scrollOffset, viewportRows: clampedRows)
        let wasEndpointVisible = visibleRows.contains(endpointScreenRow)
        var column = max(0, min(clampedColumns - 1, currentColumn))

        switch direction {
        case .left:
            column = max(0, column - clampedCount)
        case .right:
            column = min(clampedColumns - 1, column + clampedCount)
        case .beginningOfLine:
            column = 0
        case .endOfLine:
            column = clampedColumns - 1
        case .up:
            offsetEndpointScreenRow(delta: -clampedCount, totalRows: totalRows)
        case .down:
            offsetEndpointScreenRow(delta: clampedCount, totalRows: totalRows)
        case .pageUp:
            offsetEndpointScreenRow(delta: -(clampedRows * clampedCount), totalRows: totalRows)
        case .pageDown:
            offsetEndpointScreenRow(delta: clampedRows * clampedCount, totalRows: totalRows)
        case .home, .end:
            break
        }

        let scrollDelta: Int
        if !wasEndpointVisible {
            scrollDelta = 0
        } else if endpointScreenRow < visibleRows.lowerBound {
            scrollDelta = -Int(clamping: visibleRows.lowerBound - endpointScreenRow)
        } else if endpointScreenRow > visibleRows.upperBound {
            scrollDelta = Int(clamping: endpointScreenRow - visibleRows.upperBound)
        } else {
            scrollDelta = 0
        }
        let cursorScrollOffset = scrollDelta == 0
            ? scrollOffset
            : Self.pendingScrollOffset(baseOffset: scrollOffset, lineDelta: scrollDelta, totalRows: totalRows)
        let cursor = TerminalKeyboardCopyModeCursor(
            row: Self.viewportRow(forScreenRow: endpointScreenRow, scrollOffset: cursorScrollOffset, viewportRows: clampedRows),
            column: column
        )
        return (cursor, scrollDelta)
    }

    /// Derives a viewport cursor for the endpoint using the supplied column.
    ///
    /// - Parameters:
    ///   - column: The viewport column to preserve.
    ///   - viewportRows: The current terminal viewport row count.
    ///   - viewportColumns: The current terminal viewport column count.
    ///   - scrollOffset: The absolute screen row at the top of the viewport.
    /// - Returns: A viewport-relative cursor clamped into the visible grid.
    public func endpointCursor(
        column: Int,
        viewportRows: Int,
        viewportColumns: Int,
        scrollOffset: UInt64
    ) -> TerminalKeyboardCopyModeCursor {
        TerminalKeyboardCopyModeCursor(
            row: Self.viewportRow(forScreenRow: endpointScreenRow, scrollOffset: scrollOffset, viewportRows: viewportRows),
            column: max(0, min(max(viewportColumns, 1) - 1, column))
        )
    }

    /// Returns the selected rows that intersect the visible viewport.
    ///
    /// - Parameters:
    ///   - scrollOffset: The absolute screen row at the top of the viewport.
    ///   - viewportRows: The current terminal viewport row count.
    /// - Returns: The visible selected row range, or `nil` when the selection is offscreen.
    public func visibleIntersection(scrollOffset: UInt64, viewportRows: Int) -> ClosedRange<UInt64>? {
        let visibleRows = Self.visibleScreenRows(scrollOffset: scrollOffset, viewportRows: viewportRows)
        let visibleStart = max(selectedRows.lowerBound, visibleRows.lowerBound)
        let visibleEnd = min(selectedRows.upperBound, visibleRows.upperBound)
        guard visibleStart <= visibleEnd else { return nil }
        return visibleStart ... visibleEnd
    }

    /// Returns whether the entire selected range is visible in the viewport.
    ///
    /// - Parameters:
    ///   - scrollOffset: The absolute screen row at the top of the viewport.
    ///   - viewportRows: The current terminal viewport row count.
    /// - Returns: `true` when every selected row is visible.
    public func fitsVisibleRows(scrollOffset: UInt64, viewportRows: Int) -> Bool {
        let visibleRows = Self.visibleScreenRows(scrollOffset: scrollOffset, viewportRows: viewportRows)
        return selectedRows.lowerBound >= visibleRows.lowerBound
            && selectedRows.upperBound <= visibleRows.upperBound
    }

    /// Converts a viewport row into an absolute screen row.
    ///
    /// - Parameters:
    ///   - viewportRow: The row inside the current viewport.
    ///   - viewportRows: The current terminal viewport row count.
    ///   - scrollOffset: The absolute screen row at the top of the viewport.
    ///   - totalRows: The total known screen-row count, when available.
    /// - Returns: The absolute screen row.
    public static func screenRow(
        forViewportRow viewportRow: Int,
        viewportRows: Int,
        scrollOffset: UInt64,
        totalRows: UInt64?
    ) -> UInt64 {
        let rowOffset = UInt64(max(0, min(viewportRow, max(viewportRows, 1) - 1)))
        let unclampedRow = scrollOffset > UInt64.max - rowOffset
            ? UInt64.max
            : scrollOffset + rowOffset
        guard let totalRows, totalRows > 0 else { return unclampedRow }
        return min(unclampedRow, totalRows - 1)
    }

    /// Returns the absolute screen rows visible in a viewport.
    ///
    /// - Parameters:
    ///   - scrollOffset: The absolute screen row at the top of the viewport.
    ///   - viewportRows: The current terminal viewport row count.
    /// - Returns: A closed absolute screen-row range.
    public static func visibleScreenRows(scrollOffset: UInt64, viewportRows: Int) -> ClosedRange<UInt64> {
        let rowCount = UInt64(max(viewportRows, 1))
        let upperRow = scrollOffset > UInt64.max - (rowCount - 1)
            ? UInt64.max
            : scrollOffset + rowCount - 1
        return scrollOffset ... upperRow
    }

    /// Converts an absolute screen row into a viewport row.
    ///
    /// - Parameters:
    ///   - screenRow: The absolute screen row to render.
    ///   - scrollOffset: The absolute screen row at the top of the viewport.
    ///   - viewportRows: The current terminal viewport row count.
    /// - Returns: A viewport row clamped into the visible grid.
    public static func viewportRow(forScreenRow screenRow: UInt64, scrollOffset: UInt64, viewportRows: Int) -> Int {
        guard screenRow > scrollOffset else { return 0 }
        return min(max(viewportRows, 1) - 1, Int(clamping: screenRow - scrollOffset))
    }

    /// Applies a pending scroll line delta to a scroll offset.
    ///
    /// - Parameters:
    ///   - baseOffset: The current absolute scroll offset.
    ///   - lineDelta: The signed line delta being applied.
    ///   - totalRows: The total known screen-row count, when available.
    /// - Returns: The expected scroll offset after the delta.
    public static func pendingScrollOffset(baseOffset: UInt64, lineDelta: Int, totalRows: UInt64?) -> UInt64 {
        let deltaMagnitude = UInt64(clamping: lineDelta.magnitude)
        if lineDelta > 0 {
            let unclampedOffset = baseOffset > UInt64.max - deltaMagnitude
                ? UInt64.max
                : baseOffset + deltaMagnitude
            guard let totalRows, totalRows > 0 else { return unclampedOffset }
            return min(unclampedOffset, totalRows - 1)
        }
        return baseOffset > deltaMagnitude ? baseOffset - deltaMagnitude : 0
    }

    /// Resolves the scroll delta needed for a home/end viewport jump.
    ///
    /// - Parameters:
    ///   - direction: The boundary movement to apply.
    ///   - scrollOffset: The absolute screen row at the top of the viewport.
    ///   - totalRows: The total known screen-row count.
    ///   - visibleRows: The scrollbar-visible row count.
    /// - Returns: A signed line delta, or `nil` for non-boundary movements.
    public static func boundaryFallbackLineDelta(
        _ direction: TerminalKeyboardCopyModeSelectionMove,
        scrollOffset: UInt64,
        totalRows: UInt64,
        visibleRows: UInt64
    ) -> Int? {
        let targetOffset: UInt64
        switch direction {
        case .home:
            targetOffset = 0
        case .end:
            targetOffset = totalRows > visibleRows ? totalRows - visibleRows : 0
        default:
            return nil
        }

        if targetOffset >= scrollOffset {
            return Int(clamping: targetOffset - scrollOffset)
        }
        return -Int(clamping: scrollOffset - targetOffset)
    }

    /// Converts a selected range into bounded rows accepted by Ghostty's C API.
    ///
    /// - Parameters:
    ///   - selectedRows: The absolute selected screen rows.
    ///   - columns: The current terminal column count.
    ///   - maxBytes: The maximum number of formatted bytes allowed.
    /// - Returns: A lower/upper row pair, or `nil` when the selection is too large.
    public static func boundedReadRows(
        selectedRows: ClosedRange<UInt64>,
        columns: Int,
        maxBytes: UInt
    ) -> (lower: UInt32, upper: UInt32)? {
        guard columns > 0,
              let lowerRow = UInt32(exactly: selectedRows.lowerBound),
              let upperRow = UInt32(exactly: selectedRows.upperBound) else { return nil }
        let selectedRowCount = selectedRows.upperBound - selectedRows.lowerBound + 1
        let estimatedBytesPerRow = (UInt64(columns) * 4) + 1
        let maxEstimatedRows = UInt64(maxBytes) / estimatedBytesPerRow
        guard maxEstimatedRows > 0,
              selectedRowCount <= maxEstimatedRows else { return nil }
        return (lowerRow, upperRow)
    }

    private mutating func offsetEndpointScreenRow(delta: Int, totalRows: UInt64?) {
        let magnitude = UInt64(clamping: delta.magnitude)
        let moved: UInt64
        if delta > 0 {
            moved = endpointScreenRow > UInt64.max - magnitude ? UInt64.max : endpointScreenRow + magnitude
        } else {
            moved = endpointScreenRow > magnitude ? endpointScreenRow - magnitude : 0
        }

        guard let totalRows, totalRows > 0 else {
            endpointScreenRow = moved
            return
        }
        endpointScreenRow = min(moved, totalRows - 1)
    }
}
