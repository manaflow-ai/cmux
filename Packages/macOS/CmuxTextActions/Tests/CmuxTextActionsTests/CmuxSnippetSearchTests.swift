import Foundation
import Testing

@testable import CmuxTextActions

/// Flat search behind the Snippets sidebar: field coverage, AND over terms,
/// ranking tiers, and folding.
struct CmuxSnippetSearchTests {
    private func entry(
        _ id: String,
        title: String,
        category: String? = nil,
        keywords: [String] = [],
        text: String
    ) throws -> CmuxSnippetMenuEntry {
        CmuxSnippetMenuEntry(
            actionID: id,
            title: title,
            category: category,
            keywords: keywords,
            payload: try #require(CmuxTextActionPayload(text: text, submit: false))
        )
    }

    private func fixtures() throws -> [CmuxSnippetMenuEntry] {
        [
            try entry("b", title: "Beta", category: "Ops", keywords: ["restart"], text: "kubectl rollout restart"),
            try entry("a", title: "Alpha", text: "echo alpha"),
            try entry("c", title: "Café", category: "SQL", keywords: ["db"], text: "select 1"),
            try entry("d", title: "Delta", text: "something with Beta inside"),
        ]
    }

    @Test func emptyQueryReturnsEverythingInTitleOrder() throws {
        let results = CmuxSnippetSearch.filter(try fixtures(), query: "   ")
        #expect(results.map(\.actionID) == ["a", "b", "c", "d"])
    }

    @Test func termMatchesTitleCategoryKeywordsAndText() throws {
        let all = try fixtures()
        #expect(CmuxSnippetSearch.filter(all, query: "alpha").map(\.actionID) == ["a"])
        #expect(CmuxSnippetSearch.filter(all, query: "sql").map(\.actionID) == ["c"])
        #expect(CmuxSnippetSearch.filter(all, query: "restart").map(\.actionID) == ["b"])
        #expect(CmuxSnippetSearch.filter(all, query: "rollout").map(\.actionID) == ["b"])
    }

    @Test func everyTermMustMatchSomewhere() throws {
        let all = try fixtures()
        #expect(CmuxSnippetSearch.filter(all, query: "beta ops").map(\.actionID) == ["b"])
        #expect(CmuxSnippetSearch.filter(all, query: "beta nowhere").isEmpty)
    }

    @Test func titleMatchesRankAboveKeywordAndTextMatches() throws {
        // "beta" is Beta's title and appears only in Delta's text.
        let results = CmuxSnippetSearch.filter(try fixtures(), query: "beta")
        #expect(results.map(\.actionID) == ["b", "d"])
        // Keyword/category tier sits between title and text.
        let mixed = [
            try entry("t", title: "zzz", text: "ops here"),
            try entry("k", title: "yyy", keywords: ["ops"], text: "none"),
            try entry("n", title: "ops first", text: "none"),
        ]
        #expect(CmuxSnippetSearch.filter(mixed, query: "ops").map(\.actionID) == ["n", "k", "t"])
    }

    @Test func matchingIgnoresCaseAndDiacritics() throws {
        let all = try fixtures()
        #expect(CmuxSnippetSearch.filter(all, query: "CAFE").map(\.actionID) == ["c"])
        #expect(CmuxSnippetSearch.filter(all, query: "ALPHA").map(\.actionID) == ["a"])
    }

    @Test func noMatchReturnsEmptyAndEntryWithoutKeywordsStillDecodesFromOldInit() throws {
        let legacy = CmuxSnippetMenuEntry(
            actionID: "x", title: "X", category: nil,
            payload: try #require(CmuxTextActionPayload(text: "x", submit: false))
        )
        #expect(legacy.keywords.isEmpty)
        #expect(CmuxSnippetSearch.filter([legacy], query: "zzz").isEmpty)
    }
}
