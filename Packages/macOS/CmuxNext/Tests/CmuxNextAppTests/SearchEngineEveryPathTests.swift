@testable import CmuxNextBrowser
import CmuxNextSettings
@testable import CmuxNextApp
import Foundation
import Testing

/// One `browser.searchEngine` setting drives every search the app makes, in
/// WebKit and Chromium tabs alike (u2617): the omnibar's Enter and its
/// suggestions, the New Tab page's search, the page menu's Search the Web,
/// and Chromium's own default search provider. The setting is a value here,
/// never the person's config file.
@MainActor @Suite struct SearchEngineEveryPathTests {
    static func engine(_ id: String) -> OmniboxSuggestionEngine {
        var setting = BrowserOmnibarSetting()
        setting.searchEngine = id
        let engine = OmniboxSuggestionEngine()
        engine.apply(OmniboxConfiguration.resolve(setting).configuration)
        return engine
    }

    @Test func duckDuckGoReachesEverySearchPath() throws {
        let resolver = Self.engine("duckduckgo").resolver
        // Omnibar Enter (both engines share AddressBarView's resolver).
        let typed = try #require(resolver.destination(for: "cmux engine probe"))
        #expect(typed.url.absoluteString == "https://duckduckgo.com/?q=cmux%20engine%20probe")
        // Omnibar suggestions.
        #expect(resolver.searchEngine.suggestURL(for: "cmux")?.host() == "duckduckgo.com")
        // New Tab page search box.
        let plan = NewTabSubmit.plan(text: "cmux engine probe", search: true, agent: nil, resolver: resolver, home: nil)
        #expect(plan == .browser(URL(string: "https://duckduckgo.com/?q=cmux%20engine%20probe")!))
        // Page menu Search the Web (BrowserHitHandlers) and its row title.
        #expect(resolver.searchEngine.searchURL(for: "probe")?.host() == "duckduckgo.com")
        #expect(resolver.searchEngine.name == "DuckDuckGo")
        // Chromium's own default search provider.
        #expect(resolver.searchEngine.chromiumDefaultSearchJSON?.contains("https://duckduckgo.com/?q={searchTerms}") == true)
    }

    @Test func googleIsTheDefaultEverywhere() throws {
        let resolver = Self.engine("google").resolver
        let typed = try #require(resolver.destination(for: "cmux engine probe"))
        #expect(typed.url.host() == "www.google.com")
        #expect(resolver.searchEngine.chromiumDefaultSearchJSON == nil)
    }
}
