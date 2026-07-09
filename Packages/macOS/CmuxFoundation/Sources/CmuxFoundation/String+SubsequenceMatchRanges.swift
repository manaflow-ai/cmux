import Foundation

/// Case- and diacritic-insensitive subsequence fuzzy matching over a string.
extension String {
    /// Returns the ranges in `self` that, in order, match each character of `query`
    /// as a subsequence using case- and diacritic-insensitive comparison.
    ///
    /// Walks `self` left to right, consuming a `query` character each time the current
    /// character compares equal under `[.caseInsensitive, .diacriticInsensitive]`. Returns
    /// an empty array when `query` is not fully matched, when either string is empty.
    public func subsequenceMatchRanges(matching query: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var queryIndex = query.startIndex
        var textIndex = startIndex

        while queryIndex < query.endIndex, textIndex < endIndex {
            let nextTextIndex = index(after: textIndex)
            let nextQueryIndex = query.index(after: queryIndex)
            let textCharacter = String(self[textIndex..<nextTextIndex])
            let queryCharacter = String(query[queryIndex..<nextQueryIndex])
            if textCharacter.compare(
                queryCharacter,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            ) == .orderedSame {
                ranges.append(textIndex..<nextTextIndex)
                queryIndex = nextQueryIndex
            }
            textIndex = nextTextIndex
        }

        return queryIndex == query.endIndex ? ranges : []
    }
}
