import CmuxNextBrowser
@testable import CmuxNextApp
import CmuxNextSettings
import Foundation
import Testing

/// cmux.json's address bar keys become the engines' configuration: the
/// chosen built-in engine, a custom engine only when its search address has
/// a placeholder, and the remote, inline and row settings as they are.
@MainActor
struct BrowserOmnibarPreferenceTests {
    @Test func settingsMapOntoTheEngineConfiguration() {
        var setting = BrowserOmnibarSetting()
        #expect(OmniboxConfiguration(setting) == OmniboxConfiguration())
        setting.searchEngine = "brave"
        setting.remoteSuggestions = false
        setting.inlineAutocomplete = false
        setting.maxRows = 5
        let brave = OmniboxConfiguration(setting)
        #expect(brave.searchEngine == .brave && !brave.remoteSuggestions && !brave.inlineAutocomplete && brave.maxRows == 5)
        setting.searchEngine = "custom"
        setting.customSearch = "https://search.example/?q=%s"
        setting.customSuggest = "https://search.example/ac?q=%s"
        let custom = OmniboxConfiguration(setting).searchEngine
        #expect(custom.id == "custom" && custom.suggestURL(for: "a")?.absoluteString == "https://search.example/ac?q=a")
        setting.customSearch = "https://search.example/"
        #expect(OmniboxConfiguration(setting).searchEngine == .google)
    }

    @Test func everyEngineFollowsTheConfiguration() throws {
        let services = ActionBindingCoverageTests.boundServices()
        let cache = try #require(services.cache)
        cache.omniboxConfiguration = OmniboxConfiguration(searchEngine: .kagi, remoteSuggestions: false, maxRows: 4)
        for engine in cache.suggestionEngines { engine.apply(cache.omniboxConfiguration) }
        let made = cache.suggestions(for: BrowserProfileID(rawValue: UUID()))
        for engine in cache.suggestionEngines + [made] {
            #expect(engine.resolver.searchEngine == .kagi && !engine.remote.enabled && engine.maxResults == 4)
        }
        #expect(made.remote.fetcher != nil, "profile engines reach the network through the shared fetcher")
    }
}
