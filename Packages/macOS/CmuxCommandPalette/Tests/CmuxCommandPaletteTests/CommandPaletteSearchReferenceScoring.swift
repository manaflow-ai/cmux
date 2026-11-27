@testable import CmuxCommandPalette

func commandPaletteWeightedReferenceScore(
    query: String,
    title: String,
    searchableTexts: [String]
) -> Int? {
    let preparedQuery = CommandPaletteFuzzyMatcher.preparedQuery(query)
    guard let fuzzyScore = CommandPaletteFuzzyMatcher.score(
        preparedQuery: preparedQuery,
        normalizedCandidates: searchableTexts.map(CommandPaletteFuzzyMatcher.normalizeForSearch)
    ) else {
        return nil
    }
    guard let preparedTitle = CommandPaletteFuzzyMatcher.prepareCandidateText(title),
          let titleScore = CommandPaletteFuzzyMatcher.score(
            preparedQuery: preparedQuery,
            preparedCandidate: preparedTitle
          ) else {
        return fuzzyScore
    }
    return max(
        fuzzyScore,
        titleScore + 2000,
        commandPaletteTitleWordReferenceScore(preparedQuery: preparedQuery, preparedTitle: preparedTitle) ?? Int.min
    )
}

private func commandPaletteTitleWordReferenceScore(
    preparedQuery: CommandPaletteFuzzyMatcher.PreparedQuery,
    preparedTitle: CommandPaletteFuzzyMatcher.PreparedCandidateText
) -> Int? {
    guard !preparedQuery.isEmpty else { return nil }

    let titleBonus = 2000 * max(1, preparedQuery.tokens.count)
    let titleSearchWordText = commandPaletteNormalizedSearchWordText(
        characters: preparedTitle.characters,
        segments: preparedTitle.wordSegments
    )
    guard titleSearchWordText != preparedTitle.normalizedText else { return nil }

    if titleSearchWordText == preparedQuery.normalizedTokenText {
        return preparedQuery.tokens.reduce(0) { $0 + $1.scoreUpperBound } + titleBonus
    }
    if titleSearchWordText.hasPrefix(preparedQuery.normalizedTokenText) {
        return preparedQuery.tokens.reduce(0) { $0 + $1.scoreUpperBoundWithoutExactMatch } + titleBonus
    }
    return nil
}
