/// A new-side context interval omitted from the patch.
struct DiffExpansionGap: Sendable, Equatable, Hashable {
    /// Stable identity used when rows are spliced around the gap.
    let id: String
    /// First omitted new-side line, inclusive.
    let newStart: Int
    /// Last omitted new-side line, inclusive, or `nil` for an EOF gap.
    let newEnd: Int?
    /// The old-minus-new line-number delta throughout this interval.
    let oldLineDelta: Int

    /// Creates an expandable context interval.
    /// - Parameters:
    ///   - id: Stable gap identity.
    ///   - newStart: First omitted new-side line.
    ///   - newEnd: Last omitted new-side line, or `nil` when EOF is unknown.
    ///   - oldLineDelta: Offset added to a new-side number to obtain its old-side number.
    init(id: String, newStart: Int, newEnd: Int?, oldLineDelta: Int) {
        self.id = id
        self.newStart = newStart
        self.newEnd = newEnd
        self.oldLineDelta = oldLineDelta
    }

    /// The known number of omitted rows, or `nil` for an EOF gap.
    var knownLineCount: Int? {
        newEnd.map { max(0, $0 - newStart + 1) }
    }
}
