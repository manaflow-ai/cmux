/// One parsed unified-diff hunk and its line-number coordinate space.
public struct DiffHunk: Sendable, Equatable {
    /// Display-ready `@@` header line.
    public let header: DiffLine
    /// First old-file line covered by the hunk.
    public let oldStart: Int
    /// Number of old-file lines declared by the hunk header.
    public let oldCount: Int
    /// First new-file line covered by the hunk.
    public let newStart: Int
    /// Number of new-file lines declared by the hunk header.
    public let newCount: Int
    /// Optional function or section context following the second `@@`.
    public let sectionContext: String?
    /// Parsed context, changed, and no-newline marker lines in wire order.
    public let lines: [DiffLine]

    /// Creates a parsed hunk.
    /// - Parameters:
    ///   - header: Display-ready hunk header.
    ///   - oldStart: First old-file line.
    ///   - oldCount: Declared old-file line count.
    ///   - newStart: First new-file line.
    ///   - newCount: Declared new-file line count.
    ///   - sectionContext: Optional function or section context.
    ///   - lines: Parsed hunk body lines.
    public init(
        header: DiffLine,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        sectionContext: String?,
        lines: [DiffLine]
    ) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.sectionContext = sectionContext
        self.lines = lines
    }

    /// Header followed by all body lines, ready for a flat list snapshot.
    public var flattenedLines: [DiffLine] { [header] + lines }
}
