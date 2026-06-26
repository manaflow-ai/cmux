#if DEBUG
public import Foundation

/// Pure token-grid geometry for the terminal cmd-click XCUITest scenario.
///
/// `TerminalCmdClickUITestRecorder` (app target) reads the live terminal
/// surface (`terminalPanel.surface.surface`, `ghostty_surface_size`, and
/// `hostedView.bounds` + `debugCellSize`) and resolves the grid's row/column
/// count and cell size, then constructs one of these and calls
/// ``tokenPoints(visibleText:)``. The geometry math (cell insets, point
/// clamping, token-line matching, and the hit / selection-start /
/// selection-end point payloads) is a pure function of those resolved inputs
/// plus the visible terminal text, so it lives here as a tested value type
/// with no AppKit, Ghostty, or live-state coupling.
///
/// ``tokenPoints(visibleText:)`` reproduces the legacy inline `AppDelegate`
/// computation byte-for-byte: the same `[String: Any]` payload keys, the same
/// `tokenLayoutMatch` `"0"` / `"1"` flag, the same `tokenCellMetrics` map, and
/// the same middle-line / middle-occurrence token selection. The app-side
/// guards on a non-nil surface and positive `bounds`/`cellWidth`/`cellHeight`
/// stay app-side, in the original order, before the grid is constructed.
public struct TerminalCmdClickTokenGrid: Sendable {
    /// The terminal hosted-view bounds, used for centering insets and clamping.
    public let bounds: CGRect
    /// The grid row count (`max(ghostty rows, 1)`).
    public let rows: Int
    /// The grid column count (`max(ghostty columns, 1)`).
    public let cols: Int
    /// The resolved cell width (debug override, else ghostty `cell_width_px`).
    public let cellWidth: CGFloat
    /// The resolved cell height (debug override, else ghostty `cell_height_px`).
    public let cellHeight: CGFloat
    /// The rendered token searched for on each visible line.
    public let displayToken: String

    /// Creates a grid from the already-resolved geometry inputs.
    ///
    /// - Parameters:
    ///   - bounds: The terminal hosted-view bounds.
    ///   - rows: The grid row count (already `max(_, 1)`-clamped).
    ///   - cols: The grid column count (already `max(_, 1)`-clamped).
    ///   - cellWidth: The resolved positive cell width.
    ///   - cellHeight: The resolved positive cell height.
    ///   - displayToken: The rendered token to locate in the visible text.
    public init(
        bounds: CGRect,
        rows: Int,
        cols: Int,
        cellWidth: CGFloat,
        cellHeight: CGFloat,
        displayToken: String
    ) {
        self.bounds = bounds
        self.rows = rows
        self.cols = cols
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.displayToken = displayToken
    }

    /// Computes the cmd-click token-point payload for `visibleText`, or `nil`
    /// if the inputs are degenerate.
    ///
    /// - Parameter visibleText: The newline-separated visible terminal text.
    /// - Returns: The legacy `[String: Any]` token-point payload (with
    ///   `tokenLayoutMatch` `"1"` and hit/selection points when the token is
    ///   located, else `"0"` with only `tokenCellMetrics`).
    public func tokenPoints(visibleText: String) -> [String: Any]? {
        let xInset = max(0, (bounds.width - (CGFloat(cols) * cellWidth)) / 2)
        let yInset = max(0, (bounds.height - (CGFloat(rows) * cellHeight)) / 2)
        let pointClampX: (CGFloat) -> CGFloat = { x in
            min(bounds.width - 4, max(4, x))
        }
        let pointClampY: (CGFloat) -> CGFloat = { y in
            min(bounds.height - 4, max(4, y))
        }

        let rawVisibleLines = visibleText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let visibleLines = rawVisibleLines.count > rows ? Array(rawVisibleLines.suffix(rows)) : rawVisibleLines
        let rowOffset = max(0, rows - visibleLines.count)

        var matchedRowFromTop: Int?
        var matchedColumnStart: Int?
        var matchedColumnEnd: Int?
        var matchedLine = ""
        var matchingLines: [(lineIndex: Int, line: String, ranges: [Range<String.Index>])] = []

        for (lineIndex, line) in visibleLines.enumerated() {
            var searchStart = line.startIndex
            var ranges: [Range<String.Index>] = []
            while searchStart < line.endIndex,
                  let range = line.range(of: displayToken, range: searchStart..<line.endIndex) {
                ranges.append(range)
                searchStart = range.upperBound
            }
            if !ranges.isEmpty {
                matchingLines.append((lineIndex, line, ranges))
            }
        }

        if !matchingLines.isEmpty {
            let selectedLine = matchingLines[matchingLines.count / 2]
            let selectedRange = selectedLine.ranges[selectedLine.ranges.count / 2]
            let startColumn = selectedLine.line.distance(from: selectedLine.line.startIndex, to: selectedRange.lowerBound)
            let endColumnExclusive = selectedLine.line.distance(from: selectedLine.line.startIndex, to: selectedRange.upperBound)
            if startColumn < cols {
                matchedRowFromTop = rowOffset + selectedLine.lineIndex
                matchedColumnStart = startColumn
                matchedColumnEnd = max(startColumn, endColumnExclusive - 1)
                matchedLine = selectedLine.line
            }
        }

        guard let matchedRowFromTop,
              let matchedColumnStart,
              let matchedColumnEnd else {
            return [
                "tokenLayoutMatch": "0",
                "tokenCellMetrics": [
                    "cellWidth": cellWidth,
                    "cellHeight": cellHeight,
                    "columns": cols,
                    "rows": rows,
                    "xInset": xInset,
                    "yInset": yInset,
                    "visibleLineCount": visibleLines.count
                ]
            ]
        }

        let yFromTop = pointClampY(yInset + (CGFloat(matchedRowFromTop) * cellHeight) + (cellHeight / 2))
        let startX = pointClampX(xInset + (CGFloat(matchedColumnStart) * cellWidth) + (cellWidth / 2))
        let endX = pointClampX(xInset + (CGFloat(matchedColumnEnd) * cellWidth) + (cellWidth / 2))
        let hitX = pointClampX(startX + min(cellWidth * 2, max(0, endX - startX)))
        return [
            "tokenHitPointInTerminal": pointPayload(x: hitX, yFromTop: yFromTop),
            "tokenSelectionStartInTerminal": pointPayload(x: startX, yFromTop: yFromTop),
            "tokenSelectionEndInTerminal": pointPayload(x: endX, yFromTop: yFromTop),
            "tokenQuicklookWord": displayToken,
            "tokenLayoutMatch": "1",
            "tokenCellMetrics": [
                "cellWidth": cellWidth,
                "cellHeight": cellHeight,
                "columns": cols,
                "rows": rows,
                "xInset": xInset,
                "yInset": yInset,
                "visibleLineCount": visibleLines.count,
                "matchedRowFromTop": matchedRowFromTop,
                "matchedColumnStart": matchedColumnStart,
                "matchedColumnEnd": matchedColumnEnd,
                "matchedLine": matchedLine
            ]
        ]
    }

    /// Builds the `{"x", "y"}` point payload, matching the legacy inline helper.
    private func pointPayload(x: CGFloat, yFromTop: CGFloat) -> [String: Double] {
        [
            "x": x,
            "y": yFromTop
        ]
    }
}
#endif
