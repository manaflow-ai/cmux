public import Foundation

nonisolated extension OmniboxQuickIndex {
    /// The best `limit` rows for `text`, best first (`OmniboxQuickMatch.ranks`).
    ///
    /// Candidates: every word of every input token must start a word of the
    /// row; the lookup starts from the rarest word's pairs. Each candidate is
    /// then scored with `OmniboxQuickScore`, which also drops rows where a
    /// token matches neither the URL nor the title. A candidate whose best
    /// possible score cannot reach the current last row is skipped without
    /// any string work, which keeps one-letter input cheap.
    public func search(_ text: String, now: Date, limit: Int) -> [OmniboxQuickMatch] {
        guard limit > 0, !entries.isEmpty, text.utf16.count <= OmniboxText.maxInputLength else { return [] }
        let tokens = OmniboxText.queryTokens(text)
        var seen = Set<String>()
        let lookups = tokens.flatMap(OmniboxText.words).filter { seen.insert($0).inserted }
        guard !lookups.isEmpty else { return [] }
        let ranges = lookups.map { (word: $0, range: prefixRange($0)) }
        guard let seed = ranges.min(by: { $0.range.count < $1.range.count }), !seed.range.isEmpty else { return [] }
        let others = ranges.filter { $0.word != seed.word }.map(\.word)
        let spaced = tokens.map { " " + $0 }
        let prefix = OmniboxText.urlPrefix(text)
        let single = tokens.count == 1 && !prefix.isEmpty

        // The best match term a row can reach: only the first token can score
        // a host prefix (600) or a URL prefix (450), every other token at most
        // a title word (300). When the seed is the first token's first word, a
        // pair whose word does not start the host cannot reach 600 through it
        // (the row's host word, if it has the prefix, is its own pair).
        let rest = OmniboxQuickScore.titleWord * Double(tokens.count - 1)
        let seedLeads = OmniboxText.words(tokens[0]).first == seed.word
        let hostBound = (OmniboxQuickScore.hostPrefix + rest) / Double(tokens.count) + OmniboxQuickScore.maxRecency
        let otherBound = (OmniboxQuickScore.urlPrefix + rest) / Double(tokens.count) + OmniboxQuickScore.maxRecency
        // The last kept score once `best` is full: a row whose best possible
        // score is below it cannot enter.
        var floor = -Double.infinity
        var best: [OmniboxQuickMatch] = []
        var bestIDs: [Int] = []
        best.reserveCapacity(limit + 1)
        for pair in seed.range {
            let id = Int(wordEntries[pair])
            if fixed[id] + (seedLeads && !wordStartsHost[pair] ? otherBound : hostBound) < floor { continue }
            guard !bestIDs.contains(id), let entry = entries[id],
                  others.allSatisfy({ word in entry.words.contains { $0.hasPrefix(word) } }),
                  let match = OmniboxQuickScore.match(tokens: tokens, spaced: spaced, host: entry.host, url: entry.url,
                                                      titleSpaced: entry.titleSpaced) else { continue }
            let row = entry.row
            let hostPrefix = single && entry.bare.hasPrefix(prefix)
            let candidate = OmniboxQuickMatch(
                row: row,
                score: match + entry.usage + OmniboxQuickScore.recency(lastVisit: row.lastVisit, now: now)
                    + entry.brevity,
                hostPrefix: hostPrefix,
                allowsInlineCompletion: OmniboxQuickScore.allowsInlineCompletion(
                    hostPrefix: hostPrefix, visitCount: row.visitCount, typedCount: row.typedCount),
                key: entry.key, display: entry.display
            )
            guard best.count < limit || OmniboxQuickMatch.ranks(candidate, before: best[best.count - 1]) else { continue }
            let index = best.firstIndex { OmniboxQuickMatch.ranks(candidate, before: $0) } ?? best.count
            best.insert(candidate, at: index)
            bestIDs.insert(id, at: index)
            if best.count > limit {
                best.removeLast()
                bestIDs.removeLast()
            }
            if best.count == limit { floor = best[limit - 1].score }
        }
        return best
    }

    /// Every admitted row (tests compare the index with a linear scan).
    public var rows: [OmniboxHistoryRow] { entries.compactMap { $0?.row } }
}
