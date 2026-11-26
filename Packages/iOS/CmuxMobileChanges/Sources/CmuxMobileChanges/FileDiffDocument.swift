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
    /// Number of lines in the loaded raw unified-diff window.
    public let loadedLineCount: Int
    /// Number of lines in the full raw unified diff, when known.
    public let totalLineCount: Int?
    /// Working-file revision fingerprint associated with the diff, when reported.
    public let contentFingerprint: String?

    /// Creates a file diff document.
    /// - Parameters:
    ///   - hunks: Parsed hunks in source order.
    ///   - truncated: Whether the wire diff was truncated.
    ///   - isBinary: Whether the file is binary.
    ///   - loadedLineCount: Number of lines in the loaded raw diff window.
    ///   - totalLineCount: Number of lines in the full raw diff, when known.
    ///   - contentFingerprint: Working-file revision fingerprint, when reported.
    public init(
        hunks: [DiffHunk],
        truncated: Bool,
        isBinary: Bool,
        loadedLineCount: Int? = nil,
        totalLineCount: Int? = nil,
        contentFingerprint: String? = nil
    ) {
        self.hunks = hunks
        lines = hunks.flatMap(\.flattenedLines)
        self.truncated = truncated
        self.isBinary = isBinary
        self.loadedLineCount = loadedLineCount ?? lines.count
        self.totalLineCount = totalLineCount
        self.contentFingerprint = contentFingerprint
    }
}
