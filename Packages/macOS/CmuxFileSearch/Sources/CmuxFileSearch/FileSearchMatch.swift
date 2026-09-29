/// One match: one ripgrep submatch. A line with three hits yields three
/// matches that share `lineNumber` and differ in `column`.
public struct FileSearchMatch: Hashable, Sendable {
    /// 1-based line number.
    public let lineNumber: Int
    /// 1-based column in UTF-16 code units of the full line, as text views
    /// and editor `path:line:column` arguments count it.
    public let column: Int
    /// Length of the match in UTF-16 code units of the full line.
    public let length: Int
    /// A bounded excerpt of the line around the match. Leading indentation is
    /// dropped and a long prefix is replaced with an ellipsis.
    public let preview: String
    /// The match inside `preview`, as UTF-16 offsets.
    public let previewMatchRange: Range<Int>

    public init(lineNumber: Int, column: Int, length: Int, preview: String, previewMatchRange: Range<Int>) {
        self.lineNumber = lineNumber
        self.column = column
        self.length = length
        self.preview = preview
        self.previewMatchRange = previewMatchRange
    }
}

/// Matches found in one file, in ripgrep's output order.
public struct FileSearchFileMatches: Hashable, Sendable {
    public let path: String
    public var matches: [FileSearchMatch]

    public init(path: String, matches: [FileSearchMatch]) {
        self.path = path
        self.matches = matches
    }
}

extension Array where Element == FileSearchFileMatches {
    /// Appends `other`, merging a leading group into the trailing one when
    /// both name the same file so batches stay grouped across chunk borders.
    public mutating func appendMerging(_ other: [FileSearchFileMatches]) {
        for group in other {
            if let lastIndex = indices.last, self[lastIndex].path == group.path {
                self[lastIndex].matches += group.matches
            } else {
                append(group)
            }
        }
    }

    /// Total matches across every file.
    public var matchCount: Int {
        reduce(0) { $0 + $1.matches.count }
    }
}
