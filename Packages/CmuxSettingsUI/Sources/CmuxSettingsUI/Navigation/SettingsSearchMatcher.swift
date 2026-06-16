import Foundation

/// Normalizes settings search text and scores fuzzy query matches.
struct SettingsSearchMatcher: Sendable {
    #if DEBUG
    /// Debug-only sentinel that makes settings search return every indexed entry.
    let debugShowAllQuery = ":all"
    #endif

    /// Returns a case- and diacritic-folded representation of `text`.
    func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Splits text into normalized words using whitespace and punctuation boundaries.
    func tokens(in query: String) -> [String] {
        normalize(query)
            .split { character in
                character.unicodeScalars.allSatisfy { scalar in
                    CharacterSet.whitespacesAndNewlines.contains(scalar)
                        || CharacterSet.punctuationCharacters.contains(scalar)
                }
            }
            .map(String.init)
    }

    /// Splits a user query and removes words that do not help disambiguate settings.
    func queryTokens(in query: String) -> [String] {
        tokens(in: query).filter { !isSearchStopWord($0) }
    }

    /// Scores an entry for all query tokens, returning `nil` when any token misses.
    func matchScore(entry: SettingsSearchIndex.Entry, query: String, tokens: [String]) -> Int? {
        var score = 0
        for token in tokens {
            guard let tokenScore = matchScore(
                token: token,
                text: entry.normalizedSearchText,
                words: entry.normalizedSearchWords,
                wordSet: entry.normalizedSearchWordSet
            ) else {
                return nil
            }
            score += tokenScore
        }

        let title = normalize(entry.title)
        if title == query { score -= 1_000 }
        if title.hasPrefix(query) { score -= 800 }
        if containsAtWordBoundary(query, in: title) { score -= 700 }
        if entry.normalizedSearchText.hasPrefix(query) { score -= 600 }
        if containsAtWordBoundary(query, in: entry.normalizedSearchText) { score -= 500 }
        if entry.normalizedSearchText.contains(query) { score -= 400 }
        if case .section = entry.kind { score += 25 }
        return score
    }

    /// Extracts dotted setting-path tokens from a space-separated synonym string.
    func dottedTokens(in text: String) -> [String] {
        text.split(separator: " ")
            .map(String.init)
            .filter { $0.contains(".") }
    }

    /// Returns the raw dotted path plus a human-readable tokenization for matching.
    func searchTokens(forSettingPath path: String) -> [String] {
        [path, humanizedIdentifier(path)]
    }

    /// Inserts word boundaries into dotted, dashed, underscored, and camel-case identifiers.
    func humanizedIdentifier(_ identifier: String) -> String {
        var result = ""
        var previousWasLowercaseOrDigit = false
        for character in identifier {
            if character == "." || character == "-" || character == "_" {
                result.append(" ")
                previousWasLowercaseOrDigit = false
                continue
            }
            if character.isUppercase, previousWasLowercaseOrDigit {
                result.append(" ")
            }
            result.append(character)
            previousWasLowercaseOrDigit = character.isLowercase || character.isNumber
        }
        return result
    }

    private func isSearchStopWord(_ token: String) -> Bool {
        switch token {
        case "setting", "settings", "preference", "preferences":
            return true
        default:
            return false
        }
    }

    private func matchScore(token: String, text: String, words: [String], wordSet: Set<String>) -> Int? {
        if wordSet.contains(token) { return 0 }
        if words.contains(where: { $0.hasPrefix(token) }) { return 10 }
        if containsAtWordBoundary(token, in: text) { return 20 }
        if text.contains(token) { return 30 }
        if words.contains(where: { isLightTypo(token, comparedTo: $0) }) { return 50 }
        if words.contains(where: { isSubsequence(token, of: $0) }) { return 60 }
        if isSubsequence(token, of: text) { return 80 }
        return nil
    }

    private func containsAtWordBoundary(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            if range.lowerBound == haystack.startIndex {
                return true
            }
            let previous = haystack[haystack.index(before: range.lowerBound)]
            if !previous.isLetter, !previous.isNumber {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var index = needle.startIndex
        for character in haystack where character == needle[index] {
            index = needle.index(after: index)
            if index == needle.endIndex { return true }
        }
        return false
    }

    private func isLightTypo(_ token: String, comparedTo word: String) -> Bool {
        let tokenCount = token.count
        let wordCount = word.count
        guard tokenCount >= 4, wordCount >= 4 else { return false }
        let allowedDistance = min(tokenCount, wordCount) >= 6 ? 2 : 1
        guard abs(tokenCount - wordCount) <= allowedDistance else { return false }
        return editDistance(token, word, maximum: allowedDistance) <= allowedDistance
    }

    private func editDistance(_ lhs: String, _ rhs: String, maximum: Int) -> Int {
        if abs(lhs.count - rhs.count) > maximum { return maximum + 1 }
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)
        for leftIndex in 1...left.count {
            current[0] = leftIndex
            var rowMinimum = current[0]
            for rightIndex in 1...right.count {
                let cost = left[leftIndex - 1] == right[rightIndex - 1] ? 0 : 1
                current[rightIndex] = min(
                    previous[rightIndex] + 1,
                    current[rightIndex - 1] + 1,
                    previous[rightIndex - 1] + cost
                )
                rowMinimum = min(rowMinimum, current[rightIndex])
            }
            if rowMinimum > maximum { return maximum + 1 }
            swap(&previous, &current)
        }
        return previous[right.count]
    }
}
