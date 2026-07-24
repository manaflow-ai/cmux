/// One display-ready line in a parsed unified diff.
public struct DiffLine: Sendable, Equatable {
    /// The line's semantic role.
    public let kind: DiffLineKind
    /// Line text without the unified-diff `+`, `-`, or space prefix.
    /// Hunk headers retain their complete `@@ ... @@` text.
    public let text: String
    /// Old-file line number, when the line exists on the old side.
    public let oldNumber: Int?
    /// New-file line number, when the line exists on the new side.
    public let newNumber: Int?
    /// Grapheme-bound ranges to render with stronger intra-line emphasis.
    /// Each range is valid only in this value's exact ``text`` string.
    public let emphasisRanges: [Range<String.Index>]

    /// Creates a parsed diff line.
    /// - Parameters:
    ///   - kind: The line's semantic role.
    ///   - text: Display text without the diff prefix.
    ///   - oldNumber: Old-file line number.
    ///   - newNumber: New-file line number.
    ///   - emphasisRanges: Changed ranges inside `text`.
    public init(
        kind: DiffLineKind,
        text: String,
        oldNumber: Int?,
        newNumber: Int?,
        emphasisRanges: [Range<String.Index>] = []
    ) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.emphasisRanges = emphasisRanges
    }

    func replacingEmphasisRanges(_ ranges: [Range<String.Index>]) -> DiffLine {
        DiffLine(
            kind: kind,
            text: text,
            oldNumber: oldNumber,
            newNumber: newNumber,
            emphasisRanges: ranges
        )
    }
}
