import Foundation

/// The exact visual state represented by a complete render-grid snapshot.
///
/// This value is the single comparison input for both emission diffing and
/// stable content-revision tracking. Transport-only fields such as byte
/// sequence numbers, theme metadata revisions, and non-visual mode flags are
/// intentionally absent.
public struct MobileTerminalRenderGridContent: Equatable, Sendable {
    /// Number of columns in the rendered grid.
    public let columns: Int
    /// Number of rows in the rendered grid.
    public let rows: Int
    /// Active terminal screen represented by the snapshot.
    public let activeScreen: MobileTerminalRenderGridFrame.Screen
    /// Row anchor used by the producer.
    public let anchor: MobileTerminalRenderGridFrame.Anchor
    /// Canonical per-row visible text/style signatures.
    public let rowSignatures: [String]
    /// Number of retained scrollback rows represented by the snapshot.
    public let scrollbackRows: Int
    /// Canonical scrollback span signatures, oldest first.
    public let scrollbackSignatures: [String]
    /// Cursor position, when visible in the snapshot.
    public let cursor: MobileTerminalRenderGridFrame.Cursor?
    /// Dynamic terminal foreground override.
    public let terminalForeground: String?
    /// Dynamic terminal background override.
    public let terminalBackground: String?
    /// Dynamic terminal cursor-color override.
    public let terminalCursorColor: String?
    /// Resolved terminal theme.
    public let terminalTheme: TerminalTheme?
    /// Raw terminal configuration theme.
    public let terminalConfigTheme: TerminalTheme?

    /// Creates a rendered-content comparison value.
    ///
    /// - Parameters:
    ///   - columns: Number of rendered columns.
    ///   - rows: Number of rendered rows.
    ///   - activeScreen: Active terminal screen.
    ///   - anchor: Producer row anchor.
    ///   - rowSignatures: Canonical visible-row signatures.
    ///   - scrollbackRows: Number of retained scrollback rows.
    ///   - scrollbackSignatures: Canonical scrollback signatures.
    ///   - cursor: Rendered cursor position, if any.
    ///   - terminalForeground: Dynamic foreground override.
    ///   - terminalBackground: Dynamic background override.
    ///   - terminalCursorColor: Dynamic cursor-color override.
    ///   - terminalTheme: Resolved terminal theme.
    ///   - terminalConfigTheme: Raw terminal configuration theme.
    public init(
        columns: Int,
        rows: Int,
        activeScreen: MobileTerminalRenderGridFrame.Screen,
        anchor: MobileTerminalRenderGridFrame.Anchor,
        rowSignatures: [String],
        scrollbackRows: Int,
        scrollbackSignatures: [String],
        cursor: MobileTerminalRenderGridFrame.Cursor?,
        terminalForeground: String?,
        terminalBackground: String?,
        terminalCursorColor: String?,
        terminalTheme: TerminalTheme?,
        terminalConfigTheme: TerminalTheme?
    ) {
        self.columns = columns
        self.rows = rows
        self.activeScreen = activeScreen
        self.anchor = anchor
        self.rowSignatures = rowSignatures
        self.scrollbackRows = scrollbackRows
        self.scrollbackSignatures = scrollbackSignatures
        self.cursor = cursor
        self.terminalForeground = terminalForeground
        self.terminalBackground = terminalBackground
        self.terminalCursorColor = terminalCursorColor
        self.terminalTheme = terminalTheme
        self.terminalConfigTheme = terminalConfigTheme
    }
}

extension MobileTerminalRenderGridFrame {
    /// Builds one canonical visual-content snapshot for this frame.
    ///
    /// All visible and scrollback spans are ordered once by row and column.
    /// Consumers that need both a diff baseline and a revision identity can
    /// reuse the returned signatures instead of sorting or scanning the frame
    /// a second time.
    public func renderedContent() -> MobileTerminalRenderGridContent {
        var stylesByID: [Int: Style] = [:]
        for style in styles {
            // Match the frame's legacy style lookup: a later duplicate id wins
            // without turning an untrusted decoded payload into a trap.
            stylesByID[style.id] = style
        }
        let canonicalVisibleSpans = Self.canonicalSpans(rowSpans)
        let canonicalScrollbackSpans = Self.canonicalSpans(scrollbackSpans)
        let rowSignatures = Self.visibleRowSignatures(
            canonicalVisibleSpans,
            stylesByID: stylesByID,
            rowCount: rows
        )
        let scrollbackSignatures = canonicalScrollbackSpans.map { span in
            let style = stylesByID[span.styleID] ?? .default
            return Self.spanSignature(span, style: style, includeRow: true)
        }

        return MobileTerminalRenderGridContent(
            columns: columns,
            rows: rows,
            activeScreen: activeScreen,
            anchor: anchor,
            rowSignatures: rowSignatures,
            scrollbackRows: scrollbackRows,
            scrollbackSignatures: scrollbackSignatures,
            cursor: cursor,
            terminalForeground: terminalForeground,
            terminalBackground: terminalBackground,
            terminalCursorColor: terminalCursorColor,
            terminalTheme: terminalTheme,
            terminalConfigTheme: terminalConfigTheme
        )
    }

    /// Returns canonical visible-row signatures for compatibility callers.
    public func rowSignatures() -> [String] {
        var stylesByID: [Int: Style] = [:]
        for style in styles {
            stylesByID[style.id] = style
        }
        return Self.visibleRowSignatures(
            Self.canonicalSpans(rowSpans),
            stylesByID: stylesByID,
            rowCount: rows
        )
    }

    private static func visibleRowSignatures(
        _ spans: [RowSpan],
        stylesByID: [Int: Style],
        rowCount: Int
    ) -> [String] {
        var signaturesByRow = Array(repeating: [String](), count: max(0, rowCount))
        for span in spans where signaturesByRow.indices.contains(span.row) {
            let style = stylesByID[span.styleID] ?? .default
            signaturesByRow[span.row].append(
                Self.spanSignature(span, style: style, includeRow: false)
            )
        }
        return signaturesByRow.map { $0.joined(separator: "\u{1F}") }
    }

    /// Orders spans once by row, column, and original position.
    ///
    /// Ghostty exports spans in row/column order, so the common path is a single
    /// linear verification and returns the original storage without allocating.
    /// A decoded payload with out-of-order spans takes the stable sorting
    /// fallback; this keeps revision identity deterministic for untrusted input
    /// without imposing a sort on every normal frame.
    static func canonicalSpans(_ spans: [RowSpan]) -> [RowSpan] {
        guard spans.count > 1 else { return spans }
        var previous = spans[0]
        var isOrdered = true
        for span in spans.dropFirst() {
            if span.row < previous.row
                || (span.row == previous.row && span.column < previous.column) {
                isOrdered = false
                break
            }
            previous = span
        }
        guard !isOrdered else { return spans }
        return spans.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.row != rhs.element.row {
                    return lhs.element.row < rhs.element.row
                }
                if lhs.element.column != rhs.element.column {
                    return lhs.element.column < rhs.element.column
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func spanSignature(
        _ span: RowSpan,
        style: Style,
        includeRow: Bool
    ) -> String {
        let rowPrefix = includeRow ? "\(span.row):" : ""
        return rowPrefix + "\(span.column):\(span.gridCellWidth):" +
            "\(styleSignature(style)):\(span.text)"
    }

    private static func styleSignature(_ style: Style) -> String {
        let flags = [
            style.bold, style.faint, style.italic, style.underline, style.blink,
            style.inverse, style.invisible, style.strikethrough, style.overline,
        ].map { $0 ? "1" : "0" }.joined()
        let foregroundSource = style.foregroundSource?.rawValue ?? "legacy"
        let backgroundSource = style.backgroundSource?.rawValue ?? "legacy"
        return "\(style.foreground ?? "-"):\(foregroundSource):\(style.foregroundPaletteIndex ?? -1)/" +
            "\(style.background ?? "-"):\(backgroundSource):\(style.backgroundPaletteIndex ?? -1)/\(flags)"
    }
}
