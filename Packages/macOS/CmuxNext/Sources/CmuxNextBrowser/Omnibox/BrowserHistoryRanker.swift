public import Foundation

/// Scores history entries against typed text. Pure, so it is unit tested.
public nonisolated enum BrowserHistoryRanker {
    /// Score for `entry` given `text`, or nil when it does not match.
    ///
    /// Every whitespace-separated token must match the URL or the title.
    /// Host-prefix matches score highest (typing "git" should offer
    /// github.com first), then URL prefix, then word starts in the title,
    /// then any substring. Frequency and recency break ties.
    public static func score(_ entry: BrowserHistoryEntry, for text: String, now: Date) -> Double? {
        let tokens = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return nil }

        let host = strippedHost(entry.url)
        let urlText = BrowserURLDisplay.displayText(for: entry.url).lowercased()
        let title = entry.title?.lowercased() ?? ""

        var match: Double = 0
        for (index, token) in tokens.enumerated() {
            let tokenScore: Double
            if index == 0, host.hasPrefix(token) {
                tokenScore = 600
            } else if index == 0, urlText.hasPrefix(token) {
                tokenScore = 450
            } else if title.hasPrefix(token) || title.contains(" " + token) {
                tokenScore = 300
            } else if urlText.contains(token) || title.contains(token) {
                tokenScore = 150
            } else {
                return nil
            }
            match += tokenScore
        }
        match /= Double(tokens.count)

        let frequency = log2(Double(max(entry.visitCount, 1))) * 40
        let ageDays = max(now.timeIntervalSince(entry.lastVisit), 0) / 86_400
        let recency = 120 * exp(-ageDays / 14)
        // Shorter URLs win among equal matches: the site root beats deep pages.
        let brevity = max(0, 40 - Double(urlText.count) / 4)
        return match + frequency + recency + brevity
    }

    /// Key that treats `http`/`https`, `www.`, and a trailing slash as equal.
    public static func dedupeKey(for url: URL) -> String {
        var text = BrowserURLDisplay.displayText(for: url).lowercased()
        if text.hasPrefix("http://") { text.removeFirst(7) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private static func strippedHost(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
