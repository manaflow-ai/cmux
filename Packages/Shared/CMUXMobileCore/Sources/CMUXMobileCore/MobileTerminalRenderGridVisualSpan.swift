import Foundation

/// One visually resolved render-grid span independent of producer style IDs.
public struct MobileTerminalRenderGridVisualSpan: Equatable, Sendable {
    /// Zero-based column where the span begins.
    public let column: Int
    /// Number of terminal cells occupied by the span.
    public let cellWidth: Int
    /// Printable grapheme content carried by the span.
    public let text: String
    /// Fully resolved visual style with its transport ID normalized to zero.
    public let style: MobileTerminalRenderGridFrame.Style

    /// Creates a resolved visual span.
    ///
    /// - Parameters:
    ///   - column: Zero-based starting column.
    ///   - cellWidth: Number of terminal cells occupied by the span.
    ///   - text: Printable grapheme content.
    ///   - style: Resolved style with no transport identity semantics.
    public init(
        column: Int,
        cellWidth: Int,
        text: String,
        style: MobileTerminalRenderGridFrame.Style
    ) {
        self.column = column
        self.cellWidth = cellWidth
        self.text = text
        self.style = style
    }
}
