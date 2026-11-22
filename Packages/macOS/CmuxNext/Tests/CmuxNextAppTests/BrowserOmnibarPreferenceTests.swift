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

    /// A custom engine without a usable search address never searches: the
    /// address bar uses Google and says so (a fault, and the Settings row).
    @Test func aCustomEngineWithoutAPlaceholderFallsBackToGoogleAndIsReported() {
        var setting = BrowserOmnibarSetting()
        setting.searchEngine = "custom"
        for search in ["", "https://search.example/"] {
            setting.customSearch = search
            let resolved = OmniboxConfiguration.resolve(setting)
            #expect(resolved.invalidCustomEngine, "\(search)")
            #expect(resolved.configuration.searchEngine == .google)
            #expect(resolved.configuration.searchEngine.searchURL(for: "cats")?.host() == "www.google.com")
        }
        setting.customSearch = "https://search.example/?q=%s"
        let usable = OmniboxConfiguration.resolve(setting)
        #expect(!usable.invalidCustomEngine)
        #expect(usable.configuration.searchEngine.searchURL(for: "cats")?.absoluteString == "https://search.example/?q=cats")
        setting.searchEngine = "brave"
        #expect(!OmniboxConfiguration.resolve(setting).invalidCustomEngine)
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
