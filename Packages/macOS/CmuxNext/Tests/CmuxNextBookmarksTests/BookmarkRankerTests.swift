import CmuxNextBookmarks
import Foundation
import Testing

@Suite struct BookmarkRankerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func node(_ title: String, _ url: String, lastUsed: Date? = nil) -> BookmarkNode {
        var node = BookmarkNode.bookmark(title, url: URL(string: url)!, in: BookmarkRoot.bar.rawValue)
        node.lastUsed = lastUsed
        return node
    }

    @Test func everyTermMustStartATitleWordOrMatchTheURL() {
        let docs = node("Swift Concurrency Guide", "https://docs.swift.org/concurrency")
        #expect(BookmarkRanker.score(docs, for: "conc gui", now: now) != nil)
        #expect(BookmarkRanker.score(docs, for: "urrency", now: now) != nil) // URL substring
        #expect(BookmarkRanker.score(docs, for: "uide", now: now) == nil)    // not a word start, not in URL
        #expect(BookmarkRanker.score(docs, for: "swift xyz", now: now) == nil)
        #expect(BookmarkRanker.score(docs, for: "  ", now: now) == nil)
    }

    @Test func hostPrefixBeatsTitleWordBeatsURLSubstring() throws {
        let host = node("Code hosting", "https://github.com")
        let title = node("GitHub notes", "https://notes.example.com")
        let path = node("Mirror", "https://example.org/github-mirror")
        let scores = try [host, title, path].map { try #require(BookmarkRanker.score($0, for: "git", now: now)) }
        #expect(scores[0] > scores[1])
        #expect(scores[1] > scores[2])
    }

    @Test func titleCoverageAndRecentUseRaiseTheScore() throws {
        let short = node("Rust", "https://a.example/1")
        let long = node("Rust language reference and other long material", "https://a.example/2")
        let recent = node("Rust language reference and other long material", "https://a.example/3", lastUsed: now)
        let s = try #require(BookmarkRanker.score(short, for: "rust", now: now))
        let l = try #require(BookmarkRanker.score(long, for: "rust", now: now))
        let r = try #require(BookmarkRanker.score(recent, for: "rust", now: now))
        #expect(s > l)
        #expect(r > l)
    }

    @Test func aBookmarkOutranksAnEqualHistoryMatch() throws {
        // The history ranker gives a host-prefix match 600 plus at most
        // ~40 for one visit long ago and a short URL; a bookmark with the
        // same match carries the bonus on top.
        let bookmark = node("Example", "https://example.com")
        let score = try #require(BookmarkRanker.score(bookmark, for: "exa", now: now))
        #expect(score >= 600 + BookmarkRanker.bookmarkBonus)
        #expect(score < 1000)
    }

    @Test func matchesKeepOneRowPerPageAndHonorTheLimit() {
        let nodes = [node("Example", "https://example.com"), node("Example duplicate", "https://EXAMPLE.com/"),
                     node("Exam prep", "https://prep.test"), node("Unrelated", "https://zzz.test")]
        let results = BookmarkRanker.matches(in: nodes, for: "exam", now: now, limit: 5)
        #expect(results.count == 2)
        #expect(results.first?.node.title == "Example")
        #expect(BookmarkRanker.matches(in: nodes, for: "exam", now: now, limit: 1).count == 1)
    }

    @Test func searchMatchesTitleAndURLInsensitively() throws {
        var tree = BookmarkTree()
        try tree.apply(.create(.bookmark("Café Menu", url: URL(string: "https://food.test/menu")!, in: "bar", id: "c"), index: nil))
        try tree.apply(.create(.folder("Cafe folder", in: "other", id: "f"), index: nil))
        #expect(BookmarkSearch.results(tree, text: "cafe").map(\.id) == ["c", "f"])
        #expect(BookmarkSearch.results(tree, text: "food menu").map(\.id) == ["c"])
        #expect(BookmarkSearch.results(tree, text: "").isEmpty)
    }

    @Test func parseFixesUpTypedURLs() {
        #expect(BookmarkURL.parse("example.com")?.absoluteString == "https://example.com")
        #expect(BookmarkURL.parse("localhost:3000/x")?.absoluteString == "http://localhost:3000/x")
        #expect(BookmarkURL.parse("https://a.b/c")?.absoluteString == "https://a.b/c")
        #expect(BookmarkURL.parse("javascript:alert(1)")?.scheme == "javascript")
        #expect(BookmarkURL.parse("two words") == nil)
        #expect(BookmarkURL.parse("") == nil)
    }
}
