import Foundation

enum WorkspaceGroupEmojiCatalog {
    /// Every emoji in browse order (common first), from the baked dataset. No runtime scan.
    static let allEmoji: [String] = WorkspaceGroupEmojiData.entries.map(\.value)

    /// Emoji matching `rawQuery`, ranked by match quality.
    ///
    /// An empty query returns the full browse list. A single pasted emoji echoes itself.
    /// Otherwise every whitespace-separated token must appear in an entry's keywords (AND),
    /// and results are ordered exact-name, then word-prefix, then substring.
    static func search(_ rawQuery: String) -> [String] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return allEmoji }

        if let emoji = RenderableSystemSymbol.normalizedEmoji(rawQuery) {
            return [emoji]
        }

        let tokens = query.split(separator: " ").map(String.init)
        var exact: [String] = []
        var wordPrefix: [String] = []
        var substring: [String] = []

        for entry in WorkspaceGroupEmojiData.entries {
            let keywords = entry.keywords
            guard tokens.allSatisfy({ keywords.contains($0) }) else { continue }

            if keywords == query {
                exact.append(entry.value)
            } else if Self.anyWord(in: keywords, hasPrefix: tokens) {
                wordPrefix.append(entry.value)
            } else {
                substring.append(entry.value)
            }
        }

        return exact + wordPrefix + substring
    }

    /// Whether any keyword word starts with the first query token (a "rocket" query should
    /// rank `rocket` above `water pistol` even though both contain the substring).
    private static func anyWord(in keywords: String, hasPrefix tokens: [String]) -> Bool {
        guard let first = tokens.first else { return false }
        return keywords.split(separator: " ").contains { $0.hasPrefix(first) }
    }
}
