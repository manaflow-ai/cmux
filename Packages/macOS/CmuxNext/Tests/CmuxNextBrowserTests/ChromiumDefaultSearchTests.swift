import Foundation
import Testing
@testable import CmuxNextBrowser

/// `browser.searchEngine` reaches Chromium's own default search provider
/// (chrome://settings/search, Chromium's "Search … for" and image-search menu
/// rows, `chrome.search`), so a Chromium tab searches with the same engine as
/// the omnibar and every WebKit path.
@Suite struct ChromiumDefaultSearchTests {
    static func data(_ engine: BrowserSearchEngine) throws -> [String: Any] {
        let json = try #require(engine.chromiumDefaultSearchJSON)
        return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func duckDuckGoBecomesChromiumsDefaultSearch() throws {
        let data = try Self.data(.duckDuckGo)
        #expect(data["short_name"] as? String == "DuckDuckGo")
        #expect(data["keyword"] as? String == "duckduckgo.com")
        #expect(data["url"] as? String == "https://duckduckgo.com/?q={searchTerms}")
        #expect(data["suggestions_url"] as? String == "https://duckduckgo.com/ac/?q={searchTerms}&type=list")
        #expect(data["prepopulate_id"] as? Int == 92)
        #expect(data["safe_for_autoreplace"] as? Bool == false)
    }

    @Test(arguments: [BrowserSearchEngine.bing, .brave, .kagi])
    func everyOtherBuiltInEngineIsPushed(_ engine: BrowserSearchEngine) throws {
        let data = try Self.data(engine)
        #expect(data["url"] as? String == engine.queryTemplate)
        #expect(data["short_name"] as? String == engine.name)
        #expect((data["keyword"] as? String)?.hasPrefix("www.") == false)
    }

    @Test func aCustomEngineUsesItsOwnHostAndNoPrepopulatedEntry() throws {
        let custom = BrowserSearchEngine.custom(search: "https://search.example.org/find?q=%s", suggest: nil)
        let data = try Self.data(custom)
        #expect(data["url"] as? String == "https://search.example.org/find?q={searchTerms}")
        #expect(data["keyword"] as? String == "search.example.org")
        #expect(data["suggestions_url"] as? String == "")
        #expect(data["prepopulate_id"] as? Int == 0)
    }

    /// Google keeps Chromium's prepopulated Google (image search, suggest
    /// parameters): the shim resets the preference instead of writing one.
    @Test func googleKeepsChromiumsOwnGoogle() {
        #expect(BrowserSearchEngine.google.chromiumDefaultSearchJSON == nil)
    }

    /// A custom engine without a usable search address is never pushed.
    @Test func anUnusableCustomEngineIsNotPushed() {
        #expect(BrowserSearchEngine.custom(search: "not a url", suggest: nil).chromiumDefaultSearchJSON == nil)
    }
}
