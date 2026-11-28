public import Foundation

/// Omnibar ranking of bookmarks, after Chromium's BookmarkProvider: every
/// typed term must start a word of the title, or appear in the URL; the
/// share of the title the terms cover raises the score, and a bookmark
/// outranks a history page of the same match quality.
///
/// Scores use the omnibar's provider range (below the typed row's 1000):
/// history pages score up to about 600 for the match plus frequency,
/// recency and brevity bonuses (`BrowserHistoryRanker`).
public nonisolated enum BookmarkRanker {
    /// Bonus over an equal history match (a bookmarked page ranks like a
    /// typed one).
    public static let bookmarkBonus: Double = 150

    public static func score(_ node: BookmarkNode, for text: String, now: Date) -> Double? {
        guard let url = node.url else { return nil }
        let tokens = BookmarkSearch.tokens(text)
        guard !tokens.isEmpty else { return nil }
        let title = BookmarkSearch.fold(node.title)
        let words = title.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let urlText = BookmarkSearch.fold(BookmarkURL.displayText(url))
        let host = strippedHost(url)

        var match: Double = 0
        var coveredTitle = 0
        for (index, token) in tokens.enumerated() {
            if index == 0, host.hasPrefix(token) {
                match += 600
            } else if let word = words.first(where: { $0.hasPrefix(token) }) {
                match += 450
                coveredTitle += min(token.count, word.count)
            } else if urlText.contains(token) {
                match += 300
            } else {
                return nil
            }
        }
        match /= Double(tokens.count)
        // Title coverage: the fraction of the title matched.
        let coverage = title.isEmpty ? 0 : Double(coveredTitle) / Double(max(title.count, 1))
        let recency = node.lastUsed.map { 100 * exp(-max(now.timeIntervalSince($0), 0) / 86_400 / 14) } ?? 0
        let brevity = max(0, 40 - Double(urlText.count) / 4)
        return min(match + 100 * coverage + recency + brevity + bookmarkBonus, 999)
    }

    /// The best `limit` url bookmarks for `text`, highest first; one row
    /// per page (the best-named bookmark of a URL wins).
    public static func matches(in bookmarks: [BookmarkNode], for text: String, now: Date, limit: Int) -> [(node: BookmarkNode, score: Double)] {
        var best: [String: (node: BookmarkNode, score: Double)] = [:]
        for node in bookmarks {
            guard let url = node.url, let score = score(node, for: text, now: now) else { continue }
            let key = BookmarkURL.key(url)
            if let existing = best[key], existing.score >= score { continue }
            best[key] = (node, score)
        }
        return best.values.sorted { $0.score > $1.score || ($0.score == $1.score && $0.node.title < $1.node.title) }
            .prefix(limit).map { $0 }
    }

    private static func strippedHost(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// Text search over a tree, as the manager page and `cmux bookmark list
/// --search` use it: every term must appear in the title or the URL
/// (case and diacritic insensitive). Folders match by title.
public nonisolated enum BookmarkSearch {
    public static func results(_ tree: BookmarkTree, text: String) -> [BookmarkNode] {
        let terms = tokens(text)
        guard !terms.isEmpty else { return [] }
        return tree.ordered.filter { node in
            let haystack = fold(node.title) + " " + (node.url.map { fold($0.absoluteString) } ?? "")
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    static func tokens(_ text: String) -> [String] {
        fold(text).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
