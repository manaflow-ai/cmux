import Foundation

/// Semantic render-grid history owned by the mobile surface.
///
/// Render-grid frames are already terminal-rendered rows with resolved style IDs.
/// Keeping them as rows avoids rebuilding a second scrollback history by
/// replaying synthesized VT into Ghostty.
public struct MobileTerminalRenderGridSnapshot: Equatable, Sendable {
    /// Surface identifier this snapshot belongs to.
    public private(set) var surfaceID: String
    /// Monotonic render-grid sequence number applied to this snapshot.
    public private(set) var stateSeq: UInt64
    /// Current grid column count.
    public private(set) var columns: Int
    /// Current visible viewport row count.
    public private(set) var visibleRowCount: Int
    /// Active terminal screen represented by ``rows``.
    public private(set) var activeScreen: MobileTerminalRenderGridFrame.Screen
    /// Last captured cursor state for the active screen.
    public private(set) var cursor: MobileTerminalRenderGridFrame.Cursor?
    /// Dynamic terminal default foreground color, if one is active.
    public private(set) var terminalForeground: String?
    /// Dynamic terminal default background color, if one is active.
    public private(set) var terminalBackground: String?
    /// Dynamic terminal cursor color, if one is active.
    public private(set) var terminalCursorColor: String?
    /// Semantic rows for the active screen.
    public var rows: [MobileTerminalRenderGridSnapshotRow] {
        rows(for: activeScreen)
    }

    /// Plain text for every retained row on the active screen.
    public var plainText: String {
        rows.map(\.plainText).joined(separator: "\n")
    }

    /// Bounded plain text for the active screen without flattening full scrollback first.
    public func cappedPlainText(lineBudget: Int) -> MobileTerminalPlainTextCapture {
        MobileTerminalPlainTextCapture.capped(rows: rows, lineBudget: lineBudget)
    }

    private var primaryRows: [MobileTerminalRenderGridSnapshotRow]
    private var alternateRows: [MobileTerminalRenderGridSnapshotRow]
    private var primaryVisibleRowCount: Int
    private var alternateVisibleRowCount: Int
    private var primaryStylesByID: [Int: MobileTerminalRenderGridFrame.Style]
    private var alternateStylesByID: [Int: MobileTerminalRenderGridFrame.Style]

    /// Creates a semantic snapshot from a render-grid frame.
    public init(frame: MobileTerminalRenderGridFrame) {
        self.surfaceID = frame.surfaceID
        self.stateSeq = frame.stateSeq
        self.columns = frame.columns
        self.visibleRowCount = frame.rows
        self.activeScreen = frame.activeScreen
        self.cursor = frame.cursor
        self.terminalForeground = frame.terminalForeground
        self.terminalBackground = frame.terminalBackground
        self.terminalCursorColor = frame.terminalCursorColor
        let initialStylesByID = styleTable(from: frame.styles)
        let initialRows = snapshotRows(from: frame, stylesByID: initialStylesByID)
        if frame.activeScreen == .primary {
            self.primaryRows = initialRows
            self.alternateRows = []
            self.primaryVisibleRowCount = frame.rows
            self.alternateVisibleRowCount = 0
            self.primaryStylesByID = initialStylesByID
            self.alternateStylesByID = styleTable(from: [.default])
        } else {
            self.primaryRows = snapshotScrollbackRows(from: frame, stylesByID: initialStylesByID)
            self.alternateRows = Array(initialRows.suffix(frame.rows))
            self.primaryVisibleRowCount = 0
            self.alternateVisibleRowCount = frame.rows
            self.primaryStylesByID = initialStylesByID
            self.alternateStylesByID = initialStylesByID
        }
    }

    /// Number of semantic rows currently retained for the active screen.
    public var totalRows: Int {
        rows.count
    }

    /// Maximum row offset that can be rendered locally.
    public var maxRowOffset: Double {
        totalRows > visibleRowCount ? Double(totalRows - visibleRowCount) : 0
    }

    /// Applies a render-grid envelope to this snapshot.
    public mutating func apply(_ envelope: MobileTerminalRenderGridEnvelope) {
        let frame = envelope.frame
        if envelope.role == .snapshot || surfaceID != frame.surfaceID {
            self = Self(frame: frame)
            return
        }

        var targetStylesByID = stylesByID(for: frame.activeScreen)
        mergeStyles(frame.styles, into: &targetStylesByID)
        let nextViewportRows = snapshotViewportRows(from: frame, stylesByID: targetStylesByID)
        let fullViewportReplacement = isFullViewportReplacement(frame)
        var targetRows = rows(for: frame.activeScreen)
        let previousTargetVisibleRowCount = visibleRowCount(for: frame.activeScreen)
        let trailingVisibleRowCount = previousTargetVisibleRowCount
        let canAppendViewport = activeScreen == .primary &&
            frame.activeScreen == .primary &&
            frame.columns == columns &&
            frame.rows == visibleRowCount &&
            fullViewportReplacement &&
            !targetRows.isEmpty

        let oldViewportRows = visibleRowsInSnapshot(
            in: targetRows,
            rowOffset: snapshotMaxRowOffset(for: targetRows, visibleRowCount: trailingVisibleRowCount),
            visibleRowCount: trailingVisibleRowCount
        )
        if canAppendViewport,
           let overlap = viewportOverlap(old: oldViewportRows, new: nextViewportRows) {
            if overlap < nextViewportRows.count {
                targetRows.append(contentsOf: nextViewportRows.dropFirst(overlap))
            } else if let repeatedRow = nextViewportRows.last {
                targetRows.append(repeatedRow)
            }
        } else if fullViewportReplacement {
            mergeFullViewport(
                in: &targetRows,
                visibleRowCount: trailingVisibleRowCount,
                with: nextViewportRows
            )
        } else {
            patchTrailingViewport(
                in: &targetRows,
                visibleRowCount: frame.rows,
                with: nextViewportRows,
                changedRows: changedRows(in: frame)
            )
        }
        setRows(targetRows, for: frame.activeScreen)
        setStylesByID(targetStylesByID, for: frame.activeScreen)

        surfaceID = frame.surfaceID
        stateSeq = frame.stateSeq
        columns = frame.columns
        visibleRowCount = frame.rows
        activeScreen = frame.activeScreen
        setVisibleRowCount(frame.rows, for: frame.activeScreen)
        cursor = frame.cursor
        if frame.terminalForegroundIsPresent {
            terminalForeground = frame.terminalForeground
        }
        if frame.terminalBackgroundIsPresent {
            terminalBackground = frame.terminalBackground
        }
        if frame.terminalCursorColorIsPresent {
            terminalCursorColor = frame.terminalCursorColor
        }

        trimRowsToBudget()
    }

    /// Returns semantic rows visible at a local scroll offset.
    public func visibleRows(rowOffset: Double, extraRows: Int = 0) -> [MobileTerminalRenderGridSnapshotRow] {
        guard visibleRowCount > 0 else { return [] }
        let clamped = min(max(rowOffset, 0), maxRowOffset)
        let requestedRows = max(0, visibleRowCount + extraRows)
        let visible = visibleRowsInSnapshot(
            in: rows,
            rowOffset: clamped,
            visibleRowCount: visibleRowCount,
            extraRows: extraRows
        )
        var padded = visible
        while padded.count < requestedRows {
            padded.append(MobileTerminalRenderGridSnapshotRow())
        }
        return padded
    }

    /// Fractional row component of a local scroll offset.
    public func fractionalRowOffset(rowOffset: Double) -> Double {
        let clamped = min(max(rowOffset, 0), maxRowOffset)
        return clamped - clamped.rounded(.down)
    }

    private func rows(for screen: MobileTerminalRenderGridFrame.Screen) -> [MobileTerminalRenderGridSnapshotRow] {
        screen == .primary ? primaryRows : alternateRows
    }

    private mutating func setRows(
        _ rows: [MobileTerminalRenderGridSnapshotRow],
        for screen: MobileTerminalRenderGridFrame.Screen
    ) {
        if screen == .primary {
            primaryRows = rows
        } else {
            alternateRows = rows
        }
    }

    private func visibleRowCount(for screen: MobileTerminalRenderGridFrame.Screen) -> Int {
        screen == .primary ? primaryVisibleRowCount : alternateVisibleRowCount
    }

    private mutating func setVisibleRowCount(_ count: Int, for screen: MobileTerminalRenderGridFrame.Screen) {
        if screen == .primary {
            primaryVisibleRowCount = count
        } else {
            alternateVisibleRowCount = count
        }
    }

    private func stylesByID(
        for screen: MobileTerminalRenderGridFrame.Screen
    ) -> [Int: MobileTerminalRenderGridFrame.Style] {
        screen == .primary ? primaryStylesByID : alternateStylesByID
    }

    private mutating func setStylesByID(
        _ stylesByID: [Int: MobileTerminalRenderGridFrame.Style],
        for screen: MobileTerminalRenderGridFrame.Screen
    ) {
        if screen == .primary {
            primaryStylesByID = stylesByID
        } else {
            alternateStylesByID = stylesByID
        }
    }

    private mutating func trimRowsToBudget() {
        let maxRows = MobileTerminalScrollbackBudget.fullReplayRows + max(primaryVisibleRowCount, visibleRowCount, 0)
        if primaryRows.count > maxRows {
            primaryRows.removeFirst(primaryRows.count - maxRows)
        }
        let alternateLimit = max(alternateVisibleRowCount, activeScreen == .alternate ? visibleRowCount : 0, 0)
        if alternateRows.count > alternateLimit {
            alternateRows = Array(alternateRows.suffix(alternateLimit))
        }
    }

}

private func patchTrailingViewport(
    in rows: inout [MobileTerminalRenderGridSnapshotRow],
    visibleRowCount: Int,
    with viewportRows: [MobileTerminalRenderGridSnapshotRow],
    changedRows: Set<Int>
) {
    if rows.count < visibleRowCount {
        rows = Array(
            repeating: MobileTerminalRenderGridSnapshotRow(),
            count: max(0, visibleRowCount - rows.count)
        ) + rows
    }
    let viewportStart = max(0, rows.count - visibleRowCount)
    for row in changedRows where viewportRows.indices.contains(row) {
        let absoluteRow = viewportStart + row
        guard rows.indices.contains(absoluteRow) else { continue }
        rows[absoluteRow] = viewportRows[row]
    }
}

private func snapshotRows(
    from frame: MobileTerminalRenderGridFrame,
    stylesByID: [Int: MobileTerminalRenderGridFrame.Style]
) -> [MobileTerminalRenderGridSnapshotRow] {
    snapshotScrollbackRows(from: frame, stylesByID: stylesByID) +
        snapshotViewportRows(from: frame, stylesByID: stylesByID)
}

private func snapshotScrollbackRows(
    from frame: MobileTerminalRenderGridFrame,
    stylesByID: [Int: MobileTerminalRenderGridFrame.Style]
) -> [MobileTerminalRenderGridSnapshotRow] {
    groupedRows(
        spans: frame.scrollbackSpans,
        rowCount: frame.scrollbackRows,
        stylesByID: stylesByID
    )
}

private func snapshotViewportRows(
    from frame: MobileTerminalRenderGridFrame,
    stylesByID: [Int: MobileTerminalRenderGridFrame.Style]
) -> [MobileTerminalRenderGridSnapshotRow] {
    groupedRows(spans: frame.rowSpans, rowCount: frame.rows, stylesByID: stylesByID)
}

private func isFullViewportReplacement(_ frame: MobileTerminalRenderGridFrame) -> Bool {
    let cleared = Set(frame.clearedRows)
    guard cleared.count >= frame.rows else { return false }
    for row in 0..<frame.rows where !cleared.contains(row) {
        return false
    }
    return true
}

private func changedRows(in frame: MobileTerminalRenderGridFrame) -> Set<Int> {
    var rows = Set(frame.clearedRows)
    for span in frame.rowSpans {
        rows.insert(span.row)
    }
    return rows
}

private func groupedRows(
    spans: [MobileTerminalRenderGridFrame.RowSpan],
    rowCount: Int,
    stylesByID: [Int: MobileTerminalRenderGridFrame.Style]
) -> [MobileTerminalRenderGridSnapshotRow] {
    var rows = Array(repeating: MobileTerminalRenderGridSnapshotRow(), count: max(0, rowCount))
    for span in spans.sorted(by: { lhs, rhs in
        lhs.row == rhs.row ? lhs.column < rhs.column : lhs.row < rhs.row
    }) where rows.indices.contains(span.row) {
        rows[span.row].spans.append(MobileTerminalRenderGridSnapshotCellSpan(
            column: span.column,
            cellWidth: span.cellWidth ?? span.text.count,
            text: span.text,
            style: stylesByID[span.styleID] ?? .default
        ))
    }
    return rows
}

private func styleTable(
    from styles: [MobileTerminalRenderGridFrame.Style]
) -> [Int: MobileTerminalRenderGridFrame.Style] {
    var stylesByID: [Int: MobileTerminalRenderGridFrame.Style] = [0: .default]
    for style in styles {
        stylesByID[style.id] = style
    }
    return stylesByID
}

private func mergeStyles(
    _ styles: [MobileTerminalRenderGridFrame.Style],
    into stylesByID: inout [Int: MobileTerminalRenderGridFrame.Style]
) {
    if stylesByID[0] == nil {
        stylesByID[0] = .default
    }
    for style in styles {
        stylesByID[style.id] = style
    }
}

private func snapshotMaxRowOffset(for rows: [MobileTerminalRenderGridSnapshotRow], visibleRowCount: Int) -> Double {
    rows.count > visibleRowCount ? Double(rows.count - visibleRowCount) : 0
}

private func visibleRowsInSnapshot(
    in rows: [MobileTerminalRenderGridSnapshotRow],
    rowOffset: Double,
    visibleRowCount: Int,
    extraRows: Int = 0
) -> [MobileTerminalRenderGridSnapshotRow] {
    guard visibleRowCount > 0 else { return [] }
    let maxOffset = snapshotMaxRowOffset(for: rows, visibleRowCount: visibleRowCount)
    let clamped = min(max(rowOffset, 0), maxOffset)
    let requestedRows = max(0, visibleRowCount + extraRows)
    let start = min(max(Int(clamped.rounded(.down)), 0), max(0, rows.count - visibleRowCount))
    let end = min(rows.count, start + requestedRows)
    return Array(rows[start..<end])
}

private func mergeFullViewport(
    in rows: inout [MobileTerminalRenderGridSnapshotRow],
    visibleRowCount: Int,
    with viewportRows: [MobileTerminalRenderGridSnapshotRow]
) {
    if viewportRows.count <= rows.count,
       Array(rows.suffix(viewportRows.count)) == viewportRows {
        return
    }
    if let overlap = viewportOverlap(old: rows, new: viewportRows),
       overlap < viewportRows.count {
        rows.append(contentsOf: viewportRows.dropFirst(overlap))
        return
    }
    if rows.count >= visibleRowCount {
        rows.removeLast(min(visibleRowCount, rows.count))
    } else {
        rows.removeAll(keepingCapacity: true)
    }
    rows.append(contentsOf: viewportRows)
}

private func viewportOverlap(
    old: [MobileTerminalRenderGridSnapshotRow],
    new: [MobileTerminalRenderGridSnapshotRow]
) -> Int? {
    guard !old.isEmpty, !new.isEmpty else { return nil }
    let maxOverlap = min(old.count, new.count)
    for count in stride(from: maxOverlap, through: 1, by: -1) {
        if Array(old.suffix(count)) == Array(new.prefix(count)) {
            return count
        }
    }
    return nil
}

/// A bounded plain-text terminal capture for mobile copy/view-as-text flows.
public struct MobileTerminalPlainTextCapture: Equatable, Sendable {
    /// Text after applying ``lineBudget``.
    public let text: String

    /// Whether older rows were dropped to fit ``lineBudget``.
    public let isTruncated: Bool

    /// Maximum number of lines retained in ``text``.
    public let lineBudget: Int

    public init(text: String, isTruncated: Bool, lineBudget: Int) {
        self.text = text
        self.isTruncated = isTruncated
        self.lineBudget = lineBudget
    }

    /// Caps already-flattened terminal text to the last `lineBudget` lines.
    public static func capped(
        fullText: String,
        lineBudget: Int
    ) -> MobileTerminalPlainTextCapture {
        precondition(lineBudget > 0, "lineBudget must be positive")
        var lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let last = lines.last, last.allSatisfy(\.isWhitespace) {
            lines = lines.dropLast()
        }
        let isTruncated = lines.count > lineBudget
        if isTruncated {
            lines = lines.suffix(lineBudget)
        }
        return MobileTerminalPlainTextCapture(
            text: lines.joined(separator: "\n"),
            isTruncated: isTruncated,
            lineBudget: lineBudget
        )
    }

    /// Caps semantic render-grid rows without first flattening full scrollback.
    public static func capped(
        rows: [MobileTerminalRenderGridSnapshotRow],
        lineBudget: Int
    ) -> MobileTerminalPlainTextCapture {
        precondition(lineBudget > 0, "lineBudget must be positive")
        var end = rows.endIndex
        while end > rows.startIndex {
            let previous = rows.index(before: end)
            if !rows[previous].plainText.allSatisfy(\.isWhitespace) {
                break
            }
            end = previous
        }
        let retainedCount = rows.distance(from: rows.startIndex, to: end)
        let isTruncated = retainedCount > lineBudget
        let start = isTruncated
            ? rows.index(end, offsetBy: -lineBudget)
            : rows.startIndex
        let text = rows[start..<end]
            .map(\.plainText)
            .joined(separator: "\n")
        return MobileTerminalPlainTextCapture(
            text: text,
            isTruncated: isTruncated,
            lineBudget: lineBudget
        )
    }
}
