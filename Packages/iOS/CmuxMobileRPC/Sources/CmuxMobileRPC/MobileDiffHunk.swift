/// One decoded unified-diff hunk.
public struct MobileDiffHunk: Codable, Sendable, Equatable {
    /// The first old-side line covered by the hunk.
    public let oldStart: Int
    /// The number of old-side lines covered by the hunk.
    public let oldLines: Int
    /// The first new-side line covered by the hunk.
    public let newStart: Int
    /// The number of new-side lines covered by the hunk.
    public let newLines: Int
    /// Git's optional section heading.
    public let sectionHeading: String?
    /// Rows in wire order.
    public let rows: [MobileDiffRow]

    /// Creates a unified-diff hunk.
    /// - Parameters:
    ///   - oldStart: The first old-side line.
    ///   - oldLines: The number of old-side lines.
    ///   - newStart: The first new-side line.
    ///   - newLines: The number of new-side lines.
    ///   - sectionHeading: Git's optional section heading.
    ///   - rows: Rows in display order.
    public init(
        oldStart: Int,
        oldLines: Int,
        newStart: Int,
        newLines: Int,
        sectionHeading: String? = nil,
        rows: [MobileDiffRow]
    ) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.sectionHeading = sectionHeading
        self.rows = rows
    }
}
