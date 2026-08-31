public import Foundation

/// The result of scoring one sidebar row against a filter query.
///
/// Carries both the ranking score and the character positions that matched, so
/// the row can highlight exactly the characters the user typed instead of just
/// appearing in a filtered list.
public struct SidebarFilterMatch: Sendable, Equatable {
    /// The workspace this match belongs to.
    public let workspaceId: UUID
    /// The fuzzy score of the winning field, unmixed with field priority.
    public let score: Int
    /// The highest-priority field that matched.
    public let field: SidebarFilterField
    /// Matched character offsets per field.
    ///
    /// Only fields whose normalization is index-aligned with their display text
    /// appear here (see ``SidebarFilterCandidateField/isDisplayIndexAligned``),
    /// so every offset addresses the displayed string directly.
    public let matchedIndicesByField: [SidebarFilterField: Set<Int>]

    /// Creates a match.
    ///
    /// - Parameters:
    ///   - workspaceId: The matched workspace.
    ///   - score: The winning field's fuzzy score.
    ///   - field: The highest-priority field that matched.
    ///   - matchedIndicesByField: Matched offsets for every field that hit.
    public init(
        workspaceId: UUID,
        score: Int,
        field: SidebarFilterField,
        matchedIndicesByField: [SidebarFilterField: Set<Int>]
    ) {
        self.workspaceId = workspaceId
        self.score = score
        self.field = field
        self.matchedIndicesByField = matchedIndicesByField
    }

    /// Whether this match ranks above `other`.
    ///
    /// Lexicographic on `(field priority, fuzzy score)`: which field matched
    /// dominates, and the fuzzy score only separates rows that matched on the
    /// same field. Comparing raw scores across fields would let a long path
    /// coincidentally out-score a direct title hit.
    ///
    /// - Parameter other: The match to compare against.
    /// - Returns: `true` when this match should win.
    public func outranks(_ other: SidebarFilterMatch) -> Bool {
        if field.matchPriority != other.field.matchPriority {
            return field.matchPriority > other.field.matchPriority
        }
        return score > other.score
    }

    /// Contiguous highlight ranges for `field` against `displayText`.
    ///
    /// Fields whose normalization changed their character count carry no
    /// offsets at all, so the only guard here is a bounds check against the
    /// string actually being drawn.
    ///
    /// - Parameters:
    ///   - field: The field being rendered.
    ///   - displayText: The exact string the row draws.
    /// - Returns: Ascending, non-overlapping character ranges to highlight.
    public func highlightRanges(
        for field: SidebarFilterField,
        in displayText: String
    ) -> [Range<Int>] {
        guard let indices = matchedIndicesByField[field], !indices.isEmpty else { return [] }
        let displayCount = displayText.count
        guard indices.allSatisfy({ $0 >= 0 && $0 < displayCount }) else { return [] }
        var ranges: [Range<Int>] = []
        var runStart: Int?
        var previous: Int?
        for index in indices.sorted() {
            if let last = previous, index == last + 1 {
                previous = index
                continue
            }
            if let start = runStart, let last = previous {
                ranges.append(start..<(last + 1))
            }
            runStart = index
            previous = index
        }
        if let start = runStart, let last = previous {
            ranges.append(start..<(last + 1))
        }
        return ranges
    }
}
