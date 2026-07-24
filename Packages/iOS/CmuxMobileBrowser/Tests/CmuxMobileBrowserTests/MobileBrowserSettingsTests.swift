import Foundation
import Testing
@testable import CmuxMobileBrowser

@MainActor
@Suite struct MobileBrowserSettingsTests {
    @Test func defaultsToDuckDuckGo() {
        let settings = MobileBrowserSettings(defaults: Self.defaults())

        #expect(settings.defaultSearchEngine == .duckDuckGo)
        #expect(settings.searchTemplate == BrowserURLResolver.defaultSearchTemplate)
    }

    @Test func persistsSearchEngine() {
        let defaults = Self.defaults()
        var settings: MobileBrowserSettings? = MobileBrowserSettings(defaults: defaults)
        settings?.defaultSearchEngine = .google
        settings = nil

        let reloaded = MobileBrowserSettings(defaults: defaults)
        #expect(reloaded.defaultSearchEngine == .google)
    }

    @Test func searchEngineChangesFreeTextResolvedURL() throws {
        let settings = MobileBrowserSettings(defaults: Self.defaults())
        settings.defaultSearchEngine = .bing

        let url = try #require(BrowserURLResolver.resolve("swift concurrency", searchTemplate: settings.searchTemplate))
        #expect(url.absoluteString == "https://www.bing.com/search?q=swift%20concurrency")
    }

    private static func defaults() -> UserDefaults {
        let suite = "MobileBrowserSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
