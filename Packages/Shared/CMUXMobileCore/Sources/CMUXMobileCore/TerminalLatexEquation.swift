import Foundation

/// A complete LaTeX expression and the terminal cells occupied by its source.
public struct TerminalLatexEquation: Codable, Equatable, Sendable {
    /// A rectangle measured in terminal columns and rows, from the viewport's top left.
    public struct Region: Codable, Equatable, Sendable {
        /// First column.
        public var column: Int
        /// First row.
        public var row: Int
        /// Number of columns.
        public var width: Int
        /// Number of rows.
        public var height: Int
    }

    /// LaTeX without its delimiters.
    public var source: String
    /// Whether the expression uses display delimiters.
    public var display: Bool
    /// Source cells to cover only after the expression renders successfully.
    public var regions: [Region]
    /// Available space for the rendered expression, excluding adjacent prose.
    public var layout: Region
    /// Resolved terminal text color.
    public var foreground: String?
    /// Resolved terminal fill color.
    public var background: String?
}
