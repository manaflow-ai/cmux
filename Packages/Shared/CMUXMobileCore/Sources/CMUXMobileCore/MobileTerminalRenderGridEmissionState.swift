/// Cached producer state used to choose the next render-grid event payload.
///
/// A producer stores this compact state instead of the full previous
/// ``MobileTerminalRenderGridFrame`` so the hot render path can diff row
/// signatures without retaining complete viewport snapshots.
public struct MobileTerminalRenderGridEmissionState: Equatable, Sendable {
    /// Number of columns in the frame that produced this state.
    public let columns: Int
    /// Number of rows in the frame that produced this state.
    public let rows: Int
    /// Terminal byte sequence covered by the frame that produced this state.
    public let stateSeq: UInt64
    /// Process-local identity of the TerminalSurface that produced this state.
    public let producerEpoch: UInt64
    /// Terminal screen represented by the frame that produced this state.
    public let activeScreen: MobileTerminalRenderGridFrame.Screen
    /// Resolved cursor paint and geometry from the source frame.
    public let cursor: MobileTerminalRenderGridFrame.Cursor?
    /// Default style, which paints empty cells even when no row span changes.
    public let defaultStyle: MobileTerminalRenderGridFrame.Style?
    public let terminalForeground: String?
    public let terminalBackground: String?
    public let terminalCursorColor: String?
    public let terminalCursorTextColor: String?
    /// Resolved terminal theme represented by the source full frame.
    public let terminalTheme: TerminalTheme?
    /// Raw terminal configuration theme represented by the source full frame.
    public let terminalConfigTheme: TerminalTheme?
    /// Per-row text/style signatures from ``MobileTerminalRenderGridFrame/rowSignatures()``.
    public let rowSignatures: [String]

    /// Creates cached render-grid emission state.
    ///
    /// - Parameters:
    ///   - columns: Number of columns in the frame that produced this state.
    ///   - rows: Number of rows in the frame that produced this state.
    ///   - stateSeq: Terminal byte sequence covered by the source frame.
    ///   - activeScreen: Terminal screen represented by the source frame.
    ///   - terminalTheme: Resolved terminal theme represented by the source frame.
    ///   - terminalConfigTheme: Raw configuration defaults represented by the source frame.
    ///   - rowSignatures: Per-row text/style signatures for the source frame.
    ///     The count must match `rows`.
    public init(
        columns: Int,
        rows: Int,
        stateSeq: UInt64,
        producerEpoch: UInt64,
        activeScreen: MobileTerminalRenderGridFrame.Screen,
        cursor: MobileTerminalRenderGridFrame.Cursor?,
        defaultStyle: MobileTerminalRenderGridFrame.Style?,
        terminalForeground: String?,
        terminalBackground: String?,
        terminalCursorColor: String?,
        terminalCursorTextColor: String?,
        terminalTheme: TerminalTheme? = nil,
        terminalConfigTheme: TerminalTheme? = nil,
        rowSignatures: [String]
    ) {
        precondition(columns >= 0, "columns must be non-negative")
        precondition(rows >= 0, "rows must be non-negative")
        precondition(rowSignatures.count == rows, "rowSignatures count must match rows")
        self.columns = columns
        self.rows = rows
        self.stateSeq = stateSeq
        self.producerEpoch = producerEpoch
        self.activeScreen = activeScreen
        self.cursor = cursor
        self.defaultStyle = defaultStyle
        self.terminalForeground = terminalForeground
        self.terminalBackground = terminalBackground
        self.terminalCursorColor = terminalCursorColor
        self.terminalCursorTextColor = terminalCursorTextColor
        self.terminalTheme = terminalTheme
        self.terminalConfigTheme = terminalConfigTheme
        self.rowSignatures = rowSignatures
    }
}
