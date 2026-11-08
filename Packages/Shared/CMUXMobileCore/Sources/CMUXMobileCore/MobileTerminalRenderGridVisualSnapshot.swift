import Foundation

/// Canonical visual state used to verify a locally replayed render grid.
///
/// The snapshot intentionally excludes transport metadata, byte sequence,
/// capture revision, full-versus-delta encoding, scrollback, and nonvisual
/// terminal modes. Span styles are resolved before their numeric IDs are
/// discarded, so independently exported but visually identical grids compare
/// equal.
public struct MobileTerminalRenderGridVisualSnapshot: Equatable, Sendable {
    /// Visible terminal column count.
    public let columns: Int
    /// Visible terminal row count.
    public let rowCount: Int
    /// Active primary or alternate screen.
    public let activeScreen: MobileTerminalRenderGridFrame.Screen
    /// Resolved default cell style, including the visible background color.
    public let defaultStyle: MobileTerminalRenderGridFrame.Style
    /// Resolved visible spans grouped by zero-based row.
    public let rows: [[MobileTerminalRenderGridVisualSpan]]
    /// Cursor state with hollow block normalized to block.
    public let cursor: MobileTerminalRenderGridFrame.Cursor?
    /// Dynamic cursor color override, normalized for case.
    public let terminalCursorColor: String?

    /// Canonicalizes a complete render-grid frame.
    ///
    /// - Parameter fullFrame: A complete viewport frame.
    /// - Returns: `nil` when `fullFrame` is a delta.
    public init?(fullFrame: MobileTerminalRenderGridFrame) {
        guard fullFrame.full else { return nil }
        let styles = Self.normalizedStylesByID(fullFrame.styles)
        self.columns = fullFrame.columns
        self.rowCount = fullFrame.rows
        self.activeScreen = fullFrame.activeScreen
        self.defaultStyle = styles[0] ?? Self.normalizedStyle(.default)
        self.rows = Self.resolvedRows(frame: fullFrame, styles: styles)
        self.cursor = Self.normalizedCursor(fullFrame.cursor)
        self.terminalCursorColor = fullFrame.terminalCursorColor?.uppercased()
    }

    /// Applies a complete replacement or row delta to this verified baseline.
    ///
    /// Dimension or screen changes require a complete frame because a delta
    /// cannot describe the rows that moved outside its previous geometry.
    ///
    /// - Parameter frame: Complete replacement or compatible row delta.
    /// - Returns: The resulting visual snapshot, or `nil` when the delta cannot
    ///   be applied to this baseline.
    public func applying(_ frame: MobileTerminalRenderGridFrame) -> Self? {
        if frame.full {
            return Self(fullFrame: frame)
        }
        guard frame.columns == columns,
              frame.rows == rowCount,
              frame.activeScreen == activeScreen else {
            return nil
        }

        let styles = Self.normalizedStylesByID(frame.styles)
        let deltaRows = Self.resolvedRows(frame: frame, styles: styles)
        let replacedRows = Set(frame.clearedRows).union(frame.rowSpans.map(\.row))
        var nextRows = rows
        for row in replacedRows where nextRows.indices.contains(row) {
            nextRows[row] = deltaRows[row]
        }

        return Self(
            columns: columns,
            rowCount: rowCount,
            activeScreen: activeScreen,
            defaultStyle: styles[0] ?? defaultStyle,
            rows: nextRows,
            cursor: Self.normalizedCursor(frame.cursor) ?? cursor,
            terminalCursorColor: frame.terminalCursorColor?.uppercased() ?? terminalCursorColor
        )
    }

    private init(
        columns: Int,
        rowCount: Int,
        activeScreen: MobileTerminalRenderGridFrame.Screen,
        defaultStyle: MobileTerminalRenderGridFrame.Style,
        rows: [[MobileTerminalRenderGridVisualSpan]],
        cursor: MobileTerminalRenderGridFrame.Cursor?,
        terminalCursorColor: String?
    ) {
        self.columns = columns
        self.rowCount = rowCount
        self.activeScreen = activeScreen
        self.defaultStyle = defaultStyle
        self.rows = rows
        self.cursor = cursor
        self.terminalCursorColor = terminalCursorColor
    }

    private static func resolvedRows(
        frame: MobileTerminalRenderGridFrame,
        styles: [Int: MobileTerminalRenderGridFrame.Style]
    ) -> [[MobileTerminalRenderGridVisualSpan]] {
        var rows = Array(repeating: [MobileTerminalRenderGridVisualSpan](), count: frame.rows)
        for span in frame.rowSpans where rows.indices.contains(span.row) {
            rows[span.row].append(MobileTerminalRenderGridVisualSpan(
                column: span.column,
                cellWidth: span.gridCellWidth,
                text: span.text,
                style: styles[span.styleID] ?? normalizedStyle(.default)
            ))
        }
        for row in rows.indices {
            rows[row].sort {
                if $0.column != $1.column { return $0.column < $1.column }
                if $0.cellWidth != $1.cellWidth { return $0.cellWidth < $1.cellWidth }
                return $0.text < $1.text
            }
            rows[row] = canonicalizedRow(
                rows[row],
                columns: frame.columns,
                defaultStyle: styles[0] ?? normalizedStyle(.default)
            )
        }
        return rows
    }

    private static func canonicalizedRow(
        _ spans: [MobileTerminalRenderGridVisualSpan],
        columns: Int,
        defaultStyle: MobileTerminalRenderGridFrame.Style
    ) -> [MobileTerminalRenderGridVisualSpan] {
        var result: [MobileTerminalRenderGridVisualSpan] = []
        var paintedEnd = 0

        for rawSpan in spans {
            let span = normalizedBlankSpan(rawSpan, defaultStyle: defaultStyle)
            if span.column > paintedEnd {
                appendCanonicalSpan(MobileTerminalRenderGridVisualSpan(
                    column: paintedEnd,
                    cellWidth: span.column - paintedEnd,
                    text: String(repeating: " ", count: span.column - paintedEnd),
                    style: defaultStyle
                ), to: &result)
            }
            appendCanonicalSpan(span, to: &result)
            paintedEnd = max(paintedEnd, span.column + span.cellWidth)
        }
        if paintedEnd < columns {
            appendCanonicalSpan(MobileTerminalRenderGridVisualSpan(
                column: paintedEnd,
                cellWidth: columns - paintedEnd,
                text: String(repeating: " ", count: columns - paintedEnd),
                style: defaultStyle
            ), to: &result)
        }
        return result
    }

    private static func appendCanonicalSpan(
        _ span: MobileTerminalRenderGridVisualSpan,
        to result: inout [MobileTerminalRenderGridVisualSpan]
    ) {
        guard span.cellWidth > 0 else { return }
        if let previous = result.last,
           previous.column + previous.cellWidth == span.column,
           previous.style == span.style {
            result[result.count - 1] = MobileTerminalRenderGridVisualSpan(
                column: previous.column,
                cellWidth: previous.cellWidth + span.cellWidth,
                text: previous.text + span.text,
                style: previous.style
            )
        } else {
            result.append(span)
        }
    }

    private static func normalizedBlankSpan(
        _ span: MobileTerminalRenderGridVisualSpan,
        defaultStyle: MobileTerminalRenderGridFrame.Style
    ) -> MobileTerminalRenderGridVisualSpan {
        guard span.text.allSatisfy({ $0 == " " }),
              !span.style.inverse,
              !span.style.underline,
              !span.style.strikethrough,
              !span.style.overline else {
            return span
        }
        return MobileTerminalRenderGridVisualSpan(
            column: span.column,
            cellWidth: span.cellWidth,
            text: span.text,
            style: MobileTerminalRenderGridFrame.Style(
                id: span.style.id,
                foreground: defaultStyle.foreground,
                background: span.style.background,
                bold: span.style.bold,
                faint: span.style.faint,
                italic: span.style.italic,
                underline: span.style.underline,
                blink: span.style.blink,
                inverse: span.style.inverse,
                invisible: span.style.invisible,
                strikethrough: span.style.strikethrough,
                overline: span.style.overline
            )
        )
    }

    private static func normalizedStylesByID(
        _ styles: [MobileTerminalRenderGridFrame.Style]
    ) -> [Int: MobileTerminalRenderGridFrame.Style] {
        Dictionary(uniqueKeysWithValues: styles.map { ($0.id, normalizedStyle($0)) })
    }

    private static func normalizedStyle(
        _ style: MobileTerminalRenderGridFrame.Style
    ) -> MobileTerminalRenderGridFrame.Style {
        MobileTerminalRenderGridFrame.Style(
            id: 0,
            foreground: style.foreground?.uppercased(),
            background: style.background?.uppercased(),
            bold: style.bold,
            faint: style.faint,
            italic: style.italic,
            underline: style.underline,
            blink: style.blink,
            inverse: style.inverse,
            invisible: style.invisible,
            strikethrough: style.strikethrough,
            overline: style.overline
        )
    }

    private static func normalizedCursor(
        _ cursor: MobileTerminalRenderGridFrame.Cursor?
    ) -> MobileTerminalRenderGridFrame.Cursor? {
        guard var cursor else { return nil }
        if cursor.style == .blockHollow {
            cursor.style = .block
        }
        return cursor
    }
}
