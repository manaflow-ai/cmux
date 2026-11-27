import Foundation
import Testing
@testable import CmuxSettings

@Suite("BrowserSearchSettingsStore")
struct BrowserSearchSettingsStoreTests {
    @Test func configurationUsesInjectedDefaultsAndCustomProvider() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(BrowserSearchEngine.custom.rawValue, forKey: BrowserSearchSettingsStore.searchEngineKey)
        defaults.set("Kagi Fast", forKey: BrowserSearchSettingsStore.customSearchEngineNameKey)
        defaults.set(
            "https://kagi.com/search?q={query}",
            forKey: BrowserSearchSettingsStore.customSearchEngineURLTemplateKey
        )

        let configuration = BrowserSearchSettingsStore(defaults: defaults).currentConfiguration
        let url = try #require(configuration.searchURL(query: "swift actors"))

        #expect(configuration.engine == .custom)
        #expect(configuration.displayName == "Kagi Fast")
        #expect(configuration.remoteSuggestionsEngine == nil)
        #expect(url.host == "kagi.com")
        #expect(url.absoluteString.contains("q=swift%20actors"))
    }

    @Test func configurationFactoryFallsBackForInvalidCustomURLTemplate() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserSearchSettingsStore(defaults: defaults)
        let configuration = store.configuration(
            engineRaw: BrowserSearchEngine.custom.rawValue,
            customName: "",
            customURLTemplate: "ftp://search.example.test?q={query}"
        )
        let url = try #require(configuration.searchURL(query: "swift actors"))

        #expect(configuration.engine == .custom)
        #expect(configuration.displayName == BrowserSearchEngine.custom.displayName)
        #expect(configuration.customURLTemplate == BrowserSearchSettingsStore.defaultCustomSearchEngineURLTemplate)
        #expect(url.host == "www.google.com")
        #expect(url.absoluteString.contains("q=swift%20actors"))
    }

    @Test func validatesAndRendersSearchURLTemplates() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserSearchSettingsStore(defaults: defaults)
        let placeholderURL = try #require(store.searchURL(
            fromTemplate: "https://search.example.test/find?q={query}&src=cmux",
            query: "hello world"
        ))
        let appendedURL = try #require(store.searchURL(
            fromTemplate: "https://search.example.test/find?source=cmux",
            query: "c++ && swift"
        ))

        #expect(placeholderURL.absoluteString.contains("q=hello%20world"))
        #expect(placeholderURL.absoluteString.contains("src=cmux"))
        #expect(appendedURL.absoluteString.contains("source=cmux"))
        #expect(appendedURL.absoluteString.contains("q=c%2B%2B%20%26%26%20swift"))
        #expect(!appendedURL.absoluteString.contains("q=c++"))
        #expect(store.isValidSearchURLTemplate("https://search.example.test/find?q={query}"))
        #expect(!store.isValidSearchURLTemplate("cmux://search?q={query}"))
        #expect(store.searchURL(fromTemplate: "file:///tmp/search?q={query}", query: "hello world") == nil)
    }

    @Test func normalizesCustomSearchEngineNames() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = BrowserSearchSettingsStore(defaults: defaults)

        #expect(store.normalizedCustomSearchEngineName("  Kagi Fast\n") == "Kagi Fast")
        #expect(store.normalizedCustomSearchEngineName(" \n\t ") == nil)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "cmux.browserSearchSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
