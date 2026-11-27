import Foundation
import Testing
@testable import CmuxBrowser

@Suite struct BrowserHistorySuggestionEngineTests {
    private let engine = BrowserHistorySuggestionEngine()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ url: String, title: String? = nil, visitCount: Int = 1, typedCount: Int = 0) -> BrowserHistoryEntry {
        BrowserHistoryEntry(id: UUID(), url: url, title: title, lastVisited: now, visitCount: visitCount, typedCount: typedCount)
    }

    @Test func candidateStripsSchemeAndLowercases() {
        let c = engine.candidate(for: entry("HTTPS://Example.COM/Foo?A=B", title: "  Foo  "))
        #expect(c.urlLower == "https://example.com/foo?a=b")
        #expect(c.urlSansSchemeLower == "example.com/foo?a=b")
        #expect(c.hostLower == "example.com")
        #expect(c.pathAndQueryLower == "/foo?a=b")
        #expect(c.titleLower == "foo")
    }

    @Test func exactHostQueryOutranksSubstringMatch() {
        let exact = engine.candidate(for: entry("https://go.dev/", title: "Go"))
        let other = engine.candidate(for: entry("https://golang.org/doc", title: "Golang Docs"))
        let tokens = engine.tokenize(query: "go.dev")
        let exactScore = engine.score(candidate: exact, query: "go.dev", queryTokens: tokens, now: now)
        let otherScore = engine.score(candidate: other, query: "go.dev", queryTokens: tokens, now: now)
        #expect(exactScore != nil)
        #expect((exactScore ?? 0) > (otherScore ?? 0))
    }

    @Test func singleCharacterQueryRequiresPrefixMatch() {
        let prefix = engine.candidate(for: entry("https://github.com/", title: "GitHub"))
        let substringOnly = engine.candidate(for: entry("https://example.com/g", title: "Example"))
        #expect(engine.score(candidate: prefix, query: "g", queryTokens: ["g"], now: now) != nil)
        #expect(engine.score(candidate: substringOnly, query: "g", queryTokens: ["g"], now: now) == nil)
    }

    @Test func nonMatchScoresNil() {
        let c = engine.candidate(for: entry("https://example.com/", title: "Example"))
        #expect(engine.score(candidate: c, query: "zzzznomatch", queryTokens: ["zzzznomatch"], now: now) == nil)
    }

    @Test func tokenizeDedupesAndSplitsOnPunctuation() {
        #expect(engine.tokenize(query: "foo bar foo, baz") == ["foo", "bar", "baz"])
    }

    @Test func normalizedKeyDropsWWWDefaultPortAndTrailingSlash() {
        #expect(engine.normalizedHistoryKey(urlString: "https://www.example.com:443/path/") == "https://example.com/path")
        #expect(engine.normalizedHistoryKey(urlString: "http://example.com:80/") == "http://example.com/")
        #expect(engine.normalizedHistoryKey(urlString: "ftp://example.com/") == nil)
    }

    @Test func typedFrequencyRaisesScore() {
        let typed = engine.candidate(for: entry("https://typed.example/", title: "T", typedCount: 5))
        let untyped = engine.candidate(for: entry("https://typed.example/", title: "T", typedCount: 0))
        let tokens = engine.tokenize(query: "typed")
        let typedScore = engine.score(candidate: typed, query: "typed", queryTokens: tokens, now: now) ?? 0
        let untypedScore = engine.score(candidate: untyped, query: "typed", queryTokens: tokens, now: now) ?? 0
        #expect(typedScore > untypedScore)
    }
}
