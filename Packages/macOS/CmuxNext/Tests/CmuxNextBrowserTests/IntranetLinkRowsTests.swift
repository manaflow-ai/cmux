@testable import CmuxNextBrowser
import Foundation
import Testing

/// go/ links (user 2026-10-20: at Atlassian `go/gday` "just works" in Chrome
/// with no setup). Typing an intranet address offers the address first and
/// the web search right under it, as Chrome lists "go/gday - Google Search"
/// under `http://go/gday`; a public address keeps its single row.
@MainActor @Suite struct IntranetLinkRowsTests {
    @Test func aGoLinkLeadsWithTheAddressAndOffersTheSearch() async throws {
        let engine = OmniboxSuggestionEngine()
        let rows = await engine.suggestions(for: "go/gday")
        let first = try #require(rows.first)
        #expect(first.kind == .navigate)
        #expect(first.url.absoluteString == "http://go/gday")
        let search = try #require(engine.resolver.searchEngine.searchURL(for: "go/gday"))
        #expect(rows.count >= 2)
        #expect(rows.dropFirst().first?.kind == .search)
        #expect(rows.dropFirst().first?.url == search)
    }

    @Test(arguments: ["wiki/Onboarding", "devbox:8080", "jira/"])
    func otherSingleLabelAddressesOfferTheSearchToo(_ text: String) async {
        let rows = await OmniboxSuggestionEngine().suggestions(for: text)
        #expect(rows.first?.kind == .navigate)
        #expect(rows.contains { $0.kind == .search }, "\(text) offers its web search")
    }

    @Test(arguments: ["github.com", "localhost:3000", "nas.local", "192.168.1.10"])
    func otherAddressesKeepOneRow(_ text: String) async {
        let rows = await OmniboxSuggestionEngine().suggestions(for: text)
        #expect(rows.first?.kind == .navigate)
        #expect(!rows.contains { $0.kind == .search }, "\(text) adds no search row")
    }

    @Test func enterOnAGoLinkLoadsIt() throws {
        let destination = try #require(OmniboxResolver().destination(for: "go/gday"))
        #expect(destination == .url(URL(string: "http://go/gday")!))
    }
}
