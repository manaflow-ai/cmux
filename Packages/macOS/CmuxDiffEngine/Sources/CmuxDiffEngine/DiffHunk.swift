/// A parsed unified-diff hunk.
public struct DiffHunk: Sendable, Codable, Equatable {
    /// The first old-side line covered by the hunk.
    public let oldStart: Int
    /// The number of old-side lines covered by the hunk.
    public let oldLines: Int
    /// The first new-side line covered by the hunk.
    public let newStart: Int
    /// The number of new-side lines covered by the hunk.
    public let newLines: Int
    /// Git's optional section heading following the second `@@` marker.
    public let sectionHeading: String?
    /// Parsed rows in display order.
    public let rows: [DiffRow]

    /// Creates a parsed diff hunk.
    /// - Parameters:
    ///   - oldStart: The hunk's first old-side line.
    ///   - oldLines: The number of old-side lines in the hunk.
    ///   - newStart: The hunk's first new-side line.
    ///   - newLines: The number of new-side lines in the hunk.
    ///   - sectionHeading: Git's optional hunk section heading.
    ///   - rows: Parsed rows in display order.
    public init(
        oldStart: Int,
        oldLines: Int,
        newStart: Int,
        newLines: Int,
        sectionHeading: String?,
        rows: [DiffRow]
    ) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.sectionHeading = sectionHeading
        self.rows = rows
    }
}
