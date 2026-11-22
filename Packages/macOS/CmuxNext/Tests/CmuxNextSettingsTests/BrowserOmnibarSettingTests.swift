@testable import CmuxNextSettings
import Testing

/// The address bar's suggestion keys (R110): Google with remote suggestions
/// and inline completion on, 8 rows, when unset; each key parsed on its own;
/// a bad value is that key's default plus a diagnostic at its key; custom
/// templates with `%s` or `{searchTerms}` load; only inline completion and
/// the row count are agent-settable.
@Suite struct BrowserOmnibarSettingTests {
    private func parse(_ browser: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(["browser": browser], validDensities: SettingsSchemaTests.densities, validMetrics: [])
    }

    @Test func unsetIsGoogleWithSuggestions() throws {
        let setting = parse([:]).browserOmnibar
        #expect(setting == .fallback)
        #expect(setting.searchEngine == "google" && setting.remoteSuggestions && setting.inlineAutocomplete && setting.maxRows == 8)
        let row = try #require(SettingsSchema.descriptor(for: BrowserOmnibarSetting.remoteSuggestionsPath))
        #expect(row.defaultValue == .bool(true) && row.isShownInCmuxNext)
    }

    @Test func everyKeyParses() {
        let snapshot = parse([
            "searchEngine": "custom",
            "customSearchEngine": ["search": "https://search.example/find?q=%s", "suggest": "https://search.example/ac?q={searchTerms}"],
            "omnibar": ["remoteSuggestions": false, "inlineAutocomplete": false, "maxRows": 12],
        ])
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
        let setting = snapshot.browserOmnibar
        #expect(setting.searchEngine == "custom")
        #expect(setting.customSearch == "https://search.example/find?q=%s")
        #expect(setting.customSuggest == "https://search.example/ac?q={searchTerms}")
        #expect(!setting.remoteSuggestions && !setting.inlineAutocomplete && setting.maxRows == 12)
        #expect(parse(["searchEngine": "brave"]).browserOmnibar.searchEngine == "brave")
    }

    @Test func aBadValueIsItsDefaultWithADiagnostic() {
        let snapshot = parse(["searchEngine": "altavista", "omnibar": ["remoteSuggestions": "yes", "maxRows": 40]])
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["browser.searchEngine", "browser.omnibar.remoteSuggestions", "browser.omnibar.maxRows"])
        #expect(snapshot.browserOmnibar == .fallback)
    }

    /// A custom search address must say where the typed text goes: without
    /// %s or {searchTerms} it is refused when written and reported, at its
    /// key, when loaded, and the engine keeps no address.
    @Test func aCustomSearchAddressNeedsAPlaceholder() throws {
        let row = try #require(SettingsSchema.descriptor(for: BrowserOmnibarSetting.customSearchPath))
        #expect(!row.accepts("https://search.example/"))
        #expect(!row.accepts("search.example"))
        #expect(row.accepts("https://search.example/?q=%s") && row.accepts("https://search.example/?q={searchTerms}") && row.accepts(""))
        let snapshot = parse(["searchEngine": "custom", "customSearchEngine": ["search": "https://search.example/"]])
        let diagnostic = try #require(snapshot.diagnostics.first { $0.path == "browser.customSearchEngine.search" })
        #expect(diagnostic.message.contains("%s") && diagnostic.message.contains("{searchTerms}"))
        #expect(snapshot.browserOmnibar.searchEngine == "custom" && snapshot.browserOmnibar.customSearch.isEmpty)
    }

    @Test func remoteKeysAreThePersonsAndDisplayKeysAreAgentSettable() throws {
        for path in [BrowserOmnibarSetting.searchEnginePath, BrowserOmnibarSetting.customSearchPath, BrowserOmnibarSetting.customSuggestPath,
                     BrowserOmnibarSetting.remoteSuggestionsPath] {
            let row = try #require(SettingsSchema.descriptor(for: path))
            #expect(SettingsSchema.agentSettable(row) == false, "\(row.id)")
        }
        for path in [BrowserOmnibarSetting.inlineAutocompletePath, BrowserOmnibarSetting.maxRowsPath] {
            let row = try #require(SettingsSchema.descriptor(for: path))
            #expect(SettingsSchema.agentSettable(row) == true, "\(row.id)")
        }
    }
}
