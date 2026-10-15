import Foundation

/// Flat, ranked search over snippet entries for the Snippets sidebar.
///
/// The query is split on whitespace into terms. An entry matches when every
/// term is found, case- and diacritic-insensitively, in its title, category,
/// a keyword, or the text. Results are ranked by the weakest term: entries
/// whose terms all hit the title come first, then category or keyword hits,
/// then text-only hits; ties keep title order (then action id).
public enum CmuxSnippetSearch {
    public static func filter(
        _ entries: [CmuxSnippetMenuEntry],
        query: String
    ) -> [CmuxSnippetMenuEntry] {
        let ordered = entries.sorted(by: titleOrder)
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return ordered }

        var ranked: [(rank: Int, index: Int, entry: CmuxSnippetMenuEntry)] = []
        for (index, entry) in ordered.enumerated() {
            guard let rank = rank(of: entry, terms: terms) else { continue }
            ranked.append((rank, index, entry))
        }
        return ranked
            .sorted { lhs, rhs in
                lhs.rank != rhs.rank ? lhs.rank < rhs.rank : lhs.index < rhs.index
            }
            .map(\.entry)
    }

    /// 0 = every term hits the title, 1 = weakest term hits category or a
    /// keyword, 2 = weakest term hits only the text, nil = some term misses.
    private static func rank(of entry: CmuxSnippetMenuEntry, terms: [String]) -> Int? {
        var worst = 0
        for term in terms {
            if contains(entry.title, term) {
                continue
            }
            if contains(entry.category ?? "", term) || entry.keywords.contains(where: { contains($0, term) }) {
                worst = max(worst, 1)
            } else if contains(entry.payload.text, term) {
                worst = max(worst, 2)
            } else {
                return nil
            }
        }
        return worst
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func titleOrder(_ lhs: CmuxSnippetMenuEntry, _ rhs: CmuxSnippetMenuEntry) -> Bool {
        switch lhs.title.localizedStandardCompare(rhs.title) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.actionID < rhs.actionID
        }
    }
}
