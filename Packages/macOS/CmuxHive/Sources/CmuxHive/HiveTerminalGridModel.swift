public import CMUXMobileCore
import Foundation

/// Client-side reduction of a remote terminal's render-grid stream into a
/// drawable snapshot.
///
/// The host emits ``MobileTerminalRenderGridFrame`` values: a **full** frame is
/// a complete viewport snapshot; a **delta** clears `clearedRows` plus every
/// row that has spans, then repaints those rows' spans at absolute row
/// indexes. This model applies exactly those semantics (mirroring what
/// `MobileTerminalRenderGridReplay` synthesizes as VT bytes) directly onto a
/// row/span value model that a SwiftUI view renders.
///
/// Pure value type: the reduction is synchronous and deterministic, so frame
/// application is unit-testable without any transport or view.
public struct HiveTerminalGridModel: Equatable, Sendable {
    /// One styled run of text within a row.
    public struct Span: Equatable, Sendable {
        /// Zero-based start column.
        public var column: Int
        /// The resolved style for the run.
        public var style: MobileTerminalRenderGridFrame.Style
        /// The run's text.
        public var text: String
        /// The run's **total** width in grid cells (the wire `cell_width`
        /// semantics): the column advance to the next span. Wider than
        /// `text.count` when the run contains wide glyphs or host-side
        /// padding; never a per-glyph width.
        public var totalCellWidth: Int

        public init(
            column: Int,
            style: MobileTerminalRenderGridFrame.Style,
            text: String,
            totalCellWidth: Int? = nil
        ) {
            self.column = column
            self.style = style
            self.text = text
            self.totalCellWidth = totalCellWidth ?? max(1, text.renderGridEstimatedCellWidth)
        }

        /// Whether every character is a plain single-cell glyph, so the whole
        /// run can be drawn as one string at the span origin.
        public var isUniformSingleWidth: Bool { totalCellWidth == text.count }
    }

    /// Grid width in columns.
    public private(set) var columns: Int = 0
    /// Grid height in rows.
    public private(set) var rows: Int = 0
    /// Rows' styled spans, indexed by absolute row (0..<rows).
    public private(set) var rowSpans: [[Span]] = []
    /// Cursor state from the most recent frame that carried one.
    public private(set) var cursor: MobileTerminalRenderGridFrame.Cursor?
    /// The host terminal's default foreground color (`#RRGGBB`), when reported.
    public private(set) var terminalForeground: String?
    /// The host terminal's default background color (`#RRGGBB`), when reported.
    public private(set) var terminalBackground: String?
    /// The host terminal's cursor color (`#RRGGBB`), when reported.
    public private(set) var terminalCursorColor: String?
    /// The most recently applied frame's producer state sequence.
    public private(set) var stateSeq: UInt64 = 0
    /// Whether at least one full frame has been applied (the grid is drawable).
    public private(set) var hasContent = false

    public init() {}

    /// Apply one render-grid frame.
    ///
    /// A full frame replaces the whole grid; a delta clears its cleared rows
    /// plus every row it repaints, then applies the spans. A delta arriving
    /// before any full frame is ignored (the viewer requests a replay on
    /// attach, so a full frame always precedes meaningful deltas).
    public mutating func apply(_ frame: MobileTerminalRenderGridFrame) {
        let stylesByID = Dictionary(
            frame.styles.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if frame.full {
            columns = max(frame.columns, 1)
            rows = max(frame.rows, 1)
            rowSpans = Array(repeating: [], count: rows)
            hasContent = true
        } else {
            guard hasContent else { return }
            if frame.columns > 0, frame.rows > 0,
               frame.columns != columns || frame.rows != rows {
                resize(columns: frame.columns, rows: frame.rows)
            }
            for row in Set(frame.clearedRows).union(frame.rowSpans.map(\.row)) {
                guard rowSpans.indices.contains(row) else { continue }
                rowSpans[row] = []
            }
        }
        for span in frame.rowSpans {
            guard rowSpans.indices.contains(span.row), !span.text.isEmpty else { continue }
            rowSpans[span.row].append(
                Span(
                    column: span.column,
                    style: stylesByID[span.styleID] ?? .default,
                    text: span.text,
                    totalCellWidth: max(span.gridCellWidth, 1)
                )
            )
        }
        for row in Set(frame.rowSpans.map(\.row)) where rowSpans.indices.contains(row) {
            rowSpans[row].sort { $0.column < $1.column }
        }
        if frame.full || frame.cursor != nil {
            cursor = frame.cursor
        }
        if let foreground = frame.terminalForeground { terminalForeground = foreground }
        if let background = frame.terminalBackground { terminalBackground = background }
        if let cursorColor = frame.terminalCursorColor { terminalCursorColor = cursorColor }
        stateSeq = frame.stateSeq
    }

    /// The plain text of one row (spans joined with gap-filling spaces), for
    /// tests and accessibility.
    public func plainRow(_ row: Int) -> String {
        guard rowSpans.indices.contains(row) else { return "" }
        var text = ""
        var column = 0
        for span in rowSpans[row] {
            if span.column > column {
                text += String(repeating: " ", count: span.column - column)
                column = span.column
            }
            text += span.text
            column += span.totalCellWidth
        }
        return text
    }

    private mutating func resize(columns newColumns: Int, rows newRows: Int) {
        columns = newColumns
        if newRows < rows {
            rowSpans = Array(rowSpans.prefix(newRows))
        } else if newRows > rows {
            rowSpans.append(contentsOf: Array(repeating: [], count: newRows - rows))
        }
        rows = newRows
    }
}
