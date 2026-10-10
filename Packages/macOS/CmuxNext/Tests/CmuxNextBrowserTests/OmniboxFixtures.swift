@testable import CmuxNextBrowser
import Foundation
import Testing

/// SplitMix64: a seeded generator, so every random test replays exactly.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Synthetic history for the index tests and the phase A benchmark.
nonisolated enum OmniboxFixtures {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let syllables = ["git", "hub", "lab", "mail", "news", "shop", "dev", "docs", "api", "cloud", "map", "drive", "music",
                            "video", "photo", "code", "stack", "over", "flow", "book", "face", "red", "dit", "wiki", "pedia",
                            "app", "store", "bank", "home", "work"]
    static let tlds = ["com", "org", "io", "net", "dev", "co.jp"]
    static let titleWords = ["GitHub", "Pull", "Request", "Issues", "Weather", "News", "Recipes", "Docs", "Guide", "Swift",
                             "Rust", "Release", "Notes", "Inbox", "Calendar", "Maps", "日本語", "ページ", "Settings", "Dashboard"]

    static func row(_ url: String, _ title: String? = nil, visits: Int = 2, typed: Int = 0, daysAgo: Double = 1) -> OmniboxHistoryRow {
        OmniboxHistoryRow(url: URL(string: url)!, title: title, visitCount: visits, typedCount: typed,
                          lastVisit: now.addingTimeInterval(-daysAgo * 86_400))
    }

    /// `count` rows with distinct URLs.
    static func rows(_ count: Int, seed: UInt64) -> [OmniboxHistoryRow] {
        var random = SeededGenerator(seed: seed)
        return (0..<count).map { index in
            let host = syllables.randomElement(using: &random)! + syllables.randomElement(using: &random)! + "."
                + tlds.randomElement(using: &random)!
            let path = (0..<Int.random(in: 0...2, using: &random)).map { _ in syllables.randomElement(using: &random)! }
            let title = (0..<Int.random(in: 1...4, using: &random)).map { _ in titleWords.randomElement(using: &random)! }
            let url = "https://\(index % 7 == 0 ? "www." : "")\(host)/\((path + ["p\(index)"]).joined(separator: "/"))"
            return row(url, title.joined(separator: " "), visits: Int.random(in: 2...60, using: &random),
                       typed: Int.random(in: 0...9, using: &random) == 0 ? 1 : 0, daysAgo: Double.random(in: 0...90, using: &random))
        }
    }

    /// Prefixes of words the rows contain, one or two tokens.
    static func queries(_ count: Int, from rows: [OmniboxHistoryRow], seed: UInt64) -> [String] {
        var random = SeededGenerator(seed: seed)
        func prefix() -> String {
            let row = rows.randomElement(using: &random)!
            let words = OmniboxText.words(BrowserURLDisplay.displayText(for: row.url)) + OmniboxText.words(row.title ?? "")
            let word = words.randomElement(using: &random) ?? "a"
            return String(word.prefix(Int.random(in: 1...min(6, word.count), using: &random)))
        }
        return (0..<count).map { _ in Int.random(in: 0...4, using: &random) == 0 ? prefix() + " " + prefix() : prefix() }
    }

    /// The index's contract by linear scan: every input word starts a word
    /// of the row, `OmniboxQuickScore` matches, best first.
    static func reference(_ rows: [OmniboxHistoryRow], _ text: String, limit: Int) -> [OmniboxQuickMatch] {
        let tokens = OmniboxText.queryTokens(text)
        let lookups = Set(tokens.flatMap(OmniboxText.words))
        guard !lookups.isEmpty else { return [] }
        let prefix = OmniboxText.urlPrefix(text)
        return rows.compactMap { row -> OmniboxQuickMatch? in
            let display = BrowserURLDisplay.displayText(for: row.url).lowercased()
            let bare = display.hasPrefix("http://") ? String(display.dropFirst(7)) : display
            var host = row.url.host(percentEncoded: false)?.lowercased() ?? ""
            if host.hasPrefix("www.") { host.removeFirst(4) }
            let title = row.title?.lowercased() ?? ""
            let words = OmniboxText.words(bare) + OmniboxText.words(title)
            guard lookups.allSatisfy({ word in words.contains { $0.hasPrefix(word) } }),
                  let match = OmniboxQuickScore.match(tokens: tokens, spaced: tokens.map { " " + $0 }, host: host, url: display,
                                                      titleSpaced: " " + title) else { return nil }
            let hostPrefix = tokens.count == 1 && !prefix.isEmpty && bare.hasPrefix(prefix)
            return OmniboxQuickMatch(
                row: row,
                score: OmniboxQuickScore.score(match: match, visitCount: row.visitCount, typedCount: row.typedCount,
                                               lastVisit: row.lastVisit, now: now, urlLength: display.count),
                hostPrefix: hostPrefix,
                allowsInlineCompletion: OmniboxQuickScore.allowsInlineCompletion(hostPrefix: hostPrefix, visitCount: row.visitCount,
                                                                                 typedCount: row.typedCount),
                key: BrowserHistoryRanker.dedupeKey(for: row.url), display: BrowserURLDisplay.displayText(for: row.url))
        }.sorted(by: OmniboxQuickMatch.ranks).prefix(limit).map { $0 }
    }
}
