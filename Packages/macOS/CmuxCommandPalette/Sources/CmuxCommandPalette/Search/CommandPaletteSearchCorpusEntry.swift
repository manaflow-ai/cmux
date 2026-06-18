import Foundation

/// One searchable palette entry: a payload plus precomputed normalized
/// title/searchable texts, prefix scores, and the nucleo search blob.
public struct CommandPaletteSearchCorpusEntry<Payload>: Sendable where Payload: Sendable {
    /// Caller-supplied payload identifying the entry.
    public let payload: Payload
    /// Stable tie-break rank; lower wins.
    public let rank: Int
    /// Display title.
    public let title: String
    /// Prepared normalized title, or nil when the title normalizes to empty.
    public let preparedTitle: CommandPaletteFuzzyMatcher.PreparedCandidateText?
    /// Prepared normalized searchable texts (title, subtitle, keywords).
    public let preparedSearchableTexts: [CommandPaletteFuzzyMatcher.PreparedCandidateText]
    /// Set of normalized searchable texts for exact-match checks.
    public let searchableTextSet: Set<String>
    /// Precomputed best prefix scores keyed by prefix text.
    public let searchablePrefixScoreByToken: [String: Int]
    /// Newline-joined trimmed searchable texts handed to the nucleo index.
    public let nucleoSearchText: String

    /// Builds an entry, normalizing and preparing all searchable texts.
    public init(payload: Payload, rank: Int, title: String, searchableTexts: [String]) {
        self.payload = payload
        self.rank = rank
        self.title = title
        let normalizedTitle = CommandPaletteFuzzyMatcher.normalizeForSearch(title)
        self.preparedTitle = CommandPaletteFuzzyMatcher.prepareNormalizedCandidateText(normalizedTitle)

        var nucleoSearchTexts: [String] = []
        var normalizedTexts: [String] = []
        var seen: Set<String> = []
        normalizedTexts.reserveCapacity(searchableTexts.count)
        nucleoSearchTexts.reserveCapacity(searchableTexts.count)
        for text in searchableTexts {
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedText.isEmpty {
                nucleoSearchTexts.append(trimmedText)
            }
            let normalizedText = CommandPaletteFuzzyMatcher.normalizeForSearch(text)
            guard !normalizedText.isEmpty else { continue }
            guard seen.insert(normalizedText).inserted else { continue }
            normalizedTexts.append(normalizedText)
        }

        let preparedSearchableTexts = normalizedTexts.compactMap(
            CommandPaletteFuzzyMatcher.prepareNormalizedCandidateText
        )
        self.preparedSearchableTexts = preparedSearchableTexts
        self.searchableTextSet = Set(normalizedTexts)
        self.searchablePrefixScoreByToken = CommandPaletteFuzzyMatcher.wholeCandidatePrefixScoreByToken(
            preparedCandidates: preparedSearchableTexts
        )
        self.nucleoSearchText = nucleoSearchTexts.joined(separator: "\n")
    }
}
