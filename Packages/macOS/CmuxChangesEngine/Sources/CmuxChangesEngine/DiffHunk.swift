/// Contains one unified-diff hunk and its numbered rows.
public struct DiffHunk: Sendable, Equatable {
    /// The first old-side line described by the hunk.
    public let oldStart: Int
    /// The old-side line count declared by the hunk header.
    public let oldLines: Int
    /// The first new-side line described by the hunk.
    public let newStart: Int
    /// The new-side line count declared by the hunk header.
    public let newLines: Int
    /// The optional function or section text following the hunk ranges.
    public let sectionHeading: String?
    /// The rows included in this response page.
    public let rows: [DiffRow]

    /// Creates a diff hunk.
    /// - Parameters:
    ///   - oldStart: The first old-side line.
    ///   - oldLines: The declared old-side line count.
    ///   - newStart: The first new-side line.
    ///   - newLines: The declared new-side line count.
    ///   - sectionHeading: Optional section text from the hunk header.
    ///   - rows: The rows included in this page.
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
