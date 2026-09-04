import CmuxFoundation
import Testing
@testable import CmuxSettings

@Suite("Browser engine settings")
struct BrowserEngineSettingTests {
    @Test("Settings use the shared engine enum and reject unknown config values")
    func sharedEngineValue() {
        let key = BrowserCatalogSection().defaultEngine

        #expect(key.defaultValue == BrowserEngineKind.webkit)
        #expect(BrowserEngineOption(rawValue: "chromium") == .chromium)
        #expect(BrowserEngineOption(rawValue: "future-engine") == nil)
        #expect(BrowserEngineOption.decodeFromJSON("chromium") == .chromium)
        #expect(BrowserEngineOption.decodeFromJSON("future-engine") == nil)
    }
}
