import CmuxNextBrowserTabs
import Foundation
import Testing

/// The same-pane reuse rule of #17444 (#31894), in its package: which live browser tab of a pane
/// a page-requested tab reuses, and when that reuse loads the requested address.
struct BrowserTabMatchTests {
    private func tab(_ id: String, engine: String? = nil, profile: String = "default", _ shown: String?) -> BrowserTabMatch.Candidate {
        BrowserTabMatch.Candidate(id: id, engine: engine, profile: profile, shown: shown.flatMap(URL.init(string:)))
    }

    private func rule(_ url: String, engine: String = "webkit", profile: String? = nil) throws -> BrowserTabMatch {
        BrowserTabMatch(url: try #require(URL(string: url)), engine: engine, profile: profile)
    }

    @Test func theFirstTabShowingThePageInStripOrderMatches() throws {
        let tabs = [tab("a", "https://other.com/"), tab("b", "https://example.com/"), tab("c", "https://example.com/")]
        #expect(try rule("https://EXAMPLE.com/#section").first(in: tabs)?.id == "b")
    }

    @Test func anotherProfileOrEngineNeverMatches() throws {
        let tabs = [tab("a", profile: "work", "https://example.com/"), tab("b", engine: "cef", "https://example.com/")]
        #expect(try rule("https://example.com/").first(in: tabs) == nil)
        #expect(try rule("https://example.com/", profile: "work").first(in: tabs)?.id == "a")
        #expect(try rule("https://example.com/", engine: "cef").first(in: tabs)?.id == "b")
    }

    @Test func aRecordWithoutAnEngineIsWebKit() throws {
        #expect(try rule("https://example.com/").first(in: [tab("a", engine: "webkit", "https://example.com/")])?.id == "a")
        #expect(try rule("https://example.com/").first(in: [tab("a", "https://example.com/")])?.id == "a")
    }

    @Test func aTabWithNoPageOrAnotherPageNeverMatches() throws {
        let tabs = [tab("a", nil), tab("b", "https://example.com/other"), tab("c", "https://example.com/?q=1")]
        #expect(try rule("https://example.com/").first(in: tabs) == nil)
    }

    @Test func onlyAChangedFragmentNavigates() throws {
        let shown = tab("a", "https://example.com/#top")
        #expect(try rule("https://example.com/#section").navigates(shown))
        #expect(try rule("https://example.com/").navigates(shown))
        #expect(try !rule("https://example.com/#top").navigates(shown))
    }

    @Test func samePageIgnoresCaseOfSchemeAndHostATrailingSlashAndTheFragment() throws {
        func same(_ a: String, _ b: String) throws -> Bool {
            BrowserTabMatch.samePage(try #require(URL(string: a)), try #require(URL(string: b)))
        }
        #expect(try same("HTTPS://Example.COM/docs/", "https://example.com/docs#intro"))
        #expect(try same("https://example.com", "https://example.com/"))
        #expect(try !same("https://example.com/Docs", "https://example.com/docs"))
        #expect(try !same("https://example.com/a?x=1", "https://example.com/a?x=2"))
        #expect(try !same("http://example.com/", "https://example.com/"))
    }
}
