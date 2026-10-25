import CmuxNextBrowserImport
import Foundation
import Testing

/// Search Engines: a Chromium profile's default engine comes over, mapped to
/// cmux's built-in engine with the same host or kept as a custom engine.
@Suite struct ImportedSearchEngineTests {
    private static let builtIn = ["google": "https://www.google.com/search?q={searchTerms}",
                                  "duckduckgo": "https://duckduckgo.com/?q={searchTerms}"]

    private static func profile(_ preferences: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "search-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(preferences.utf8).write(to: folder.appending(path: "Preferences"))
        return folder
    }

    @Test func aBuiltInEngineMapsToItsID() throws {
        let folder = try Self.profile(#"""
        {"default_search_provider_data":{"template_url_data":{"short_name":"DuckDuckGo","keyword":"duckduckgo.com",
          "url":"https://duckduckgo.com/?q={searchTerms}&t={google:originalQueryForSuggestion}"}}}
        """#)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = try #require(ChromiumSearchEngineReader().read(profile: folder))
        #expect(engine.search == "https://duckduckgo.com/?q={searchTerms}")
        #expect(engine.setting(builtIn: Self.builtIn).engine == "duckduckgo")
    }

    @Test func anOtherEngineIsCustomWithItsAddresses() throws {
        let folder = try Self.profile(#"""
        {"default_search_provider_data":{"template_url_data":{"short_name":"Kagi","keyword":"kagi",
          "url":"https://kagi.com/search?q={searchTerms}","suggestions_url":"https://kagi.com/api/autosuggest?q={searchTerms}"}}}
        """#)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = try #require(ChromiumSearchEngineReader().read(profile: folder))
        let setting = engine.setting(builtIn: Self.builtIn)
        #expect(setting.engine == "custom")
        #expect(setting.search == "https://kagi.com/search?q={searchTerms}")
        #expect(setting.suggest == "https://kagi.com/api/autosuggest?q={searchTerms}")
    }

    @Test func theBrowsersOwnDefaultOrAnInsecureEngineIsNothing() throws {
        let plain = try Self.profile(#"{"profile":{"name":"Work"}}"#)
        let insecure = try Self.profile(#"{"default_search_provider_data":{"template_url_data":{"url":"http://example.com/?q={searchTerms}"}}}"#)
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: insecure)
        }
        #expect(ChromiumSearchEngineReader().read(profile: plain) == nil)
        #expect(ChromiumSearchEngineReader().read(profile: insecure) == nil)
    }
}
