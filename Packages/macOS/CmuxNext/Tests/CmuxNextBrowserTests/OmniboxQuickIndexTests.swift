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

/// The quick history index (plans/cmux-next/omnibar-suggestions.md): the
/// exact score, admission and cap rules, and property tests that the sorted
/// word arrays, the incremental updates and the pruning return exactly what
/// a linear scan with the same rules returns.
nonisolated struct OmniboxQuickIndexTests {
    typealias F = OmniboxFixtures

    @Test func scoreIsExactlyTheDesignFormula() throws {
        var index = OmniboxQuickIndex()
        index.reset([F.row("https://github.com/", "GitHub", visits: 8, typed: 1, daysAgo: 7)], now: F.now)
        let host = try #require(index.search("git", now: F.now, limit: 8).first)
        let usage = 200 + log2(8.0) * 40
        let dynamic = 120 * exp(-7.0 / 14) + (40 - 10.0 / 4)
        #expect(abs(host.score - (600 + usage + dynamic)) < 1e-9)
        #expect(host.hostPrefix && host.allowsInlineCompletion)
        // Second token "com": a substring of the URL (150); the mean of 600 and 150.
        let two = try #require(index.search("git com", now: F.now, limit: 8).first)
        #expect(abs(two.score - (375 + usage + dynamic)) < 1e-9)
        #expect(!two.hostPrefix)
        // A title word start (300), not the URL's start.
        index.reset([F.row("https://example.com/a", "Release Notes", visits: 1, daysAgo: 0)], now: F.now)
        let title = try #require(index.search("notes", now: F.now, limit: 8).first)
        #expect(abs(title.score - (300 + 0 + 120 + (40 - 13.0 / 4))) < 1e-9)
    }

    @Test func onlySignificantRowsEnterUpToTheCap() {
        var index = OmniboxQuickIndex()
        index.reset([
            F.row("https://once-old.example/", visits: 1, daysAgo: 10),
            F.row("https://once-recent.example/", visits: 1, daysAgo: 0.5),
            F.row("https://typed-old.example/", visits: 1, typed: 1, daysAgo: 60),
            F.row("https://twice-old.example/", visits: 2, daysAgo: 60),
        ], now: F.now)
        #expect(index.count == 3)
        #expect(!index.contains(URL(string: "https://once-old.example/")!))

        var capped = OmniboxQuickIndex(cap: 2)
        capped.reset([
            F.row("https://weak.example/", visits: 2, daysAgo: 80),
            F.row("https://strong.example/", visits: 50, typed: 1, daysAgo: 0),
            F.row("https://middle.example/", visits: 10, daysAgo: 3),
        ], now: F.now)
        #expect(capped.count == 2)
        #expect(!capped.contains(URL(string: "https://weak.example/")!))
        capped.upsert(F.row("https://weaker.example/", visits: 2, daysAgo: 89), now: F.now)
        #expect(!capped.contains(URL(string: "https://weaker.example/")!))
        capped.upsert(F.row("https://stronger.example/", visits: 99, typed: 3, daysAgo: 0), now: F.now)
        #expect(capped.count == 2 && capped.contains(URL(string: "https://stronger.example/")!))
    }

    @Test func indexEqualsALinearScan() {
        // Hosts whose first word is not where the display starts, files, ports, punycode.
        let odd = ["http://www.foo/", "http://localhost:3000/x", "file:///Users/me/doc.html", "https://xn--nxasmq6b.com/",
                   "http://127.0.0.1:8080/admin", "https://www.example.co.jp/news"].map { F.row($0, "Odd Page", visits: 9, typed: 1) }
        let rows = F.rows(400, seed: 7) + odd
        var index = OmniboxQuickIndex()
        index.reset(rows, now: F.now)
        let extra = ["fo", "www", "www.fo", "local", "3000", "users", "doc", "xn", "127", "127.0", "8080", "exam", "odd p"]
        for query in F.queries(300, from: rows, seed: 11) + extra {
            #expect(index.search(query, now: F.now, limit: 8) == F.reference(rows, query, limit: 8), "\(query)")
        }
    }

    @Test func incrementalUpdatesEqualARebuild() {
        var random = SeededGenerator(seed: 3)
        let rows = F.rows(300, seed: 5)
        var built = OmniboxQuickIndex()
        built.reset([], now: F.now)
        for row in rows.shuffled(using: &random) { built.upsert(row, now: F.now) }
        let removed = Set(rows.shuffled(using: &random).prefix(60).map(\.url))
        for url in removed { built.remove(url) }
        // Changed titles and counts arrive as upserts of the same URL.
        var kept = rows.filter { !removed.contains($0.url) }
        for index in stride(from: 0, to: kept.count, by: 9) {
            kept[index].title = "Renamed Swift Guide"
            kept[index].visitCount += 7
            built.upsert(kept[index], now: F.now)
        }
        var fresh = OmniboxQuickIndex()
        fresh.reset(kept.reversed(), now: F.now)
        for query in F.queries(200, from: kept, seed: 13) + ["renamed", "swift gu"] {
            let incremental = built.search(query, now: F.now, limit: 8)
            #expect(incremental == fresh.search(query, now: F.now, limit: 8), "\(query)")
            #expect(incremental == F.reference(kept, query, limit: 8), "\(query)")
        }
    }

    @Test func equalInputGivesEqualOutput() {
        let rows = F.rows(200, seed: 21)
        var index = OmniboxQuickIndex()
        index.reset(rows, now: F.now)
        var shuffled = OmniboxQuickIndex()
        var random = SeededGenerator(seed: 4)
        shuffled.reset(rows.shuffled(using: &random), now: F.now)
        for query in F.queries(100, from: rows, seed: 2) {
            let first = index.search(query, now: F.now, limit: 8)
            #expect(first == index.search(query, now: F.now, limit: 8))
            #expect(first == shuffled.search(query, now: F.now, limit: 8))
            #expect(zip(first, first.dropFirst()).allSatisfy { OmniboxQuickMatch.ranks($0, before: $1) })
        }
    }

    @Test func wordsSplitURLsAndTitles() {
        #expect(OmniboxText.words("github.com/manaflow-ai/cmux") == ["github", "com", "manaflow", "ai", "cmux"])
        #expect(OmniboxText.words("日本語のページ — Docs") == ["日本語のページ", "docs"])
        #expect(OmniboxText.urlPrefix(" HTTPS://www.GitHub.com/x") == "github.com/x")
        #expect(OmniboxText.queryTokens("  Git   Hub ") == ["git", "hub"])
    }
}
