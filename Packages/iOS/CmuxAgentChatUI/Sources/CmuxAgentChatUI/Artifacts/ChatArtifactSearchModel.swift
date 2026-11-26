import Foundation

/// Pure literal-search state over the currently loaded UTF-16 text range.
struct ChatArtifactSearchModel: Equatable, Sendable {
    private(set) var query: String
    private(set) var matchRanges: [NSRange]
    private(set) var selectedMatchIndex: Int?

    init(query: String = "", text: String = "") {
        self.query = query
        matchRanges = Self.ranges(of: query, in: text)
        selectedMatchIndex = matchRanges.isEmpty ? nil : 0
    }

    var currentRange: NSRange? {
        guard let selectedMatchIndex,
              matchRanges.indices.contains(selectedMatchIndex) else {
            return nil
        }
        return matchRanges[selectedMatchIndex]
    }

    var summary: ChatArtifactSearchSummary {
        ChatArtifactSearchSummary(
            currentPosition: selectedMatchIndex.map { $0 + 1 } ?? 0,
            matchCount: matchRanges.count
        )
    }

    /// Replaces the literal query and starts selection at the first loaded match.
    mutating func update(query: String, in text: String) {
        guard query == self.query else {
            self.query = query
            matchRanges = Self.ranges(of: query, in: text)
            selectedMatchIndex = matchRanges.isEmpty ? nil : 0
            return
        }
        recompute(in: text)
    }

    /// Recomputes after a stream append while preserving the current match when possible.
    mutating func recompute(in text: String) {
        let selectedRange = currentRange
        matchRanges = Self.ranges(of: query, in: text)
        if let selectedRange,
           let preservedIndex = matchRanges.firstIndex(of: selectedRange) {
            selectedMatchIndex = preservedIndex
        } else {
            selectedMatchIndex = matchRanges.isEmpty ? nil : 0
        }
    }

    /// Advances to the next result, wrapping from the last match to the first.
    mutating func selectNext() {
        guard !matchRanges.isEmpty else {
            selectedMatchIndex = nil
            return
        }
        selectedMatchIndex = ((selectedMatchIndex ?? -1) + 1) % matchRanges.count
    }

    /// Moves to the previous result, wrapping from the first match to the last.
    mutating func selectPrevious() {
        guard !matchRanges.isEmpty else {
            selectedMatchIndex = nil
            return
        }
        let currentIndex = selectedMatchIndex ?? 0
        selectedMatchIndex = (currentIndex - 1 + matchRanges.count) % matchRanges.count
    }

    private static func ranges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let source = text as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var results: [NSRange] = []

        while searchRange.length > 0 {
            let match = source.range(
                of: query,
                options: [.caseInsensitive, .literal],
                range: searchRange
            )
            guard match.location != NSNotFound else { break }
            results.append(match)
            let nextLocation = NSMaxRange(match)
            guard nextLocation > searchRange.location else { break }
            searchRange = NSRange(
                location: nextLocation,
                length: source.length - nextLocation
            )
        }
        return results
    }
}
