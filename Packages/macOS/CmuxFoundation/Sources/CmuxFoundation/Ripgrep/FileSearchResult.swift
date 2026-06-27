/// A single ripgrep match: the matched file plus the line, column, and a
/// trimmed preview of the matching line, used to render a file-search result.
///
/// `path` is the absolute path emitted by `rg`; `relativePath` is that path made
/// relative to the search root for display.
public struct FileSearchResult: Equatable, Sendable {
    /// Absolute path of the matched file.
    public let path: String
    /// `path` made relative to the search root, for display.
    public let relativePath: String
    /// 1-based line number of the match.
    public let lineNumber: Int
    /// 1-based column number of the match.
    public let columnNumber: Int
    /// Whitespace-trimmed text of the matching line.
    public let preview: String

    /// - Parameters:
    ///   - path: absolute path of the matched file.
    ///   - relativePath: `path` relative to the search root.
    ///   - lineNumber: 1-based line number of the match.
    ///   - columnNumber: 1-based column number of the match.
    ///   - preview: whitespace-trimmed text of the matching line.
    public init(
        path: String,
        relativePath: String,
        lineNumber: Int,
        columnNumber: Int,
        preview: String
    ) {
        self.path = path
        self.relativePath = relativePath
        self.lineNumber = lineNumber
        self.columnNumber = columnNumber
        self.preview = preview
    }
}
