/// Contains one unified-diff hunk and its numbered rows.
public struct MobileChangesHunk: Codable, Sendable, Equatable {
    /// The first old-side line described by the hunk header.
    public let oldStart: Int
    /// The old-side line count declared by the hunk header.
    public let oldLines: Int
    /// The first new-side line described by the hunk header.
    public let newStart: Int
    /// The new-side line count declared by the hunk header.
    public let newLines: Int
    /// The optional trailing section heading from the hunk header.
    public let sectionHeading: String?
    /// The hunk's ordered diff rows.
    public let rows: [MobileChangesDiffRow]

    /// Creates a unified-diff hunk.
    /// - Parameters:
    ///   - oldStart: The first old-side line described by the hunk.
    ///   - oldLines: The old-side line count.
    ///   - newStart: The first new-side line described by the hunk.
    ///   - newLines: The new-side line count.
    ///   - sectionHeading: The optional trailing section heading.
    ///   - rows: The hunk's ordered diff rows.
    public init(
        oldStart: Int,
        oldLines: Int,
        newStart: Int,
        newLines: Int,
        sectionHeading: String?,
        rows: [MobileChangesDiffRow]
    ) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.sectionHeading = sectionHeading
        self.rows = rows
    }

    private enum CodingKeys: String, CodingKey {
        case oldStart = "old_start"
        case oldLines = "old_lines"
        case newStart = "new_start"
        case newLines = "new_lines"
        case sectionHeading = "section_heading"
        case rows
    }
}
