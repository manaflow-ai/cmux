/// A display-ready parsed file diff with explicit and flattened hunk structure.
public struct FileDiffDocument: Sendable, Equatable {
    /// Parsed hunks in source order.
    public let hunks: [DiffHunk]
    /// All hunk headers and body lines flattened in display order.
    public let lines: [DiffLine]
    /// Whether the host omitted complete hunks because of its response cap.
    public let truncated: Bool
    /// Whether the file is binary and therefore has no textual hunks.
    public let isBinary: Bool

    /// Creates a file diff document.
    /// - Parameters:
    ///   - hunks: Parsed hunks in source order.
    ///   - truncated: Whether the wire diff was truncated.
    ///   - isBinary: Whether the file is binary.
    public init(hunks: [DiffHunk], truncated: Bool, isBinary: Bool) {
        self.hunks = hunks
        lines = hunks.flatMap(\.flattenedLines)
        self.truncated = truncated
        self.isBinary = isBinary
    }
}
