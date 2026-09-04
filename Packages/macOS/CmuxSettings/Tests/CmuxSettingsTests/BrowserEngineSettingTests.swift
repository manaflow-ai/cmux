import CmuxFoundation
import Testing
@testable import CmuxSettings

@Suite("Browser engine settings")
struct BrowserEngineSettingTests {
    @Test("Settings use the shared preference enum and default to auto")
    func sharedEngineValue() {
        let key = BrowserCatalogSection().defaultEngine

        #expect(key.defaultValue == BrowserEngineDefaultChoice.auto)
        #expect(BrowserEngineOption(rawValue: "auto") == .auto)
        #expect(BrowserEngineOption(rawValue: "chromium") == .chromium)
        #expect(BrowserEngineOption(rawValue: "webkit") == .webkit)
        #expect(BrowserEngineOption(rawValue: "future-engine") == nil)
        #expect(BrowserEngineOption.decodeFromJSON("auto") == .auto)
        #expect(BrowserEngineOption.decodeFromJSON("chromium") == .chromium)
        #expect(BrowserEngineOption.decodeFromJSON("future-engine") == nil)
    }

    @Test("Auto resolves from the system default browser; explicit choices pin")
    func autoResolution() {
        #expect(BrowserEngineDefaultChoice.auto.resolvedEngine(systemDefaultBrowserIsChromium: true) == .chromium)
        #expect(BrowserEngineDefaultChoice.auto.resolvedEngine(systemDefaultBrowserIsChromium: false) == .webkit)
        #expect(BrowserEngineDefaultChoice.webkit.resolvedEngine(systemDefaultBrowserIsChromium: true) == .webkit)
        #expect(BrowserEngineDefaultChoice.chromium.resolvedEngine(systemDefaultBrowserIsChromium: false) == .chromium)
    }

    @Test("Chromium-family detection is a conservative bundle-id allowlist")
    func chromiumFamilyBundleIdentifiers() {
        let chromiumFamily = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "company.thebrowser.Browser",
            "company.thebrowser.dia",
            "com.vivaldi.Vivaldi",
            "org.chromium.Chromium",
        ]
        for identifier in chromiumFamily {
            #expect(BrowserEngineDefaultChoice.isChromiumFamilyBundleIdentifier(identifier))
        }
        let webkitOrUnknown = ["com.apple.Safari", "org.mozilla.firefox", "com.example.someapp", ""]
        for identifier in webkitOrUnknown {
            #expect(!BrowserEngineDefaultChoice.isChromiumFamilyBundleIdentifier(identifier))
        }
        #expect(!BrowserEngineDefaultChoice.isChromiumFamilyBundleIdentifier(nil))
    }

    @Test("Persisted spellings keep explicit choices and fall back to auto")
    func persistedSpellings() {
        #expect(BrowserEngineDefaultChoice(persistedRawValue: "webkit") == .webkit)
        #expect(BrowserEngineDefaultChoice(persistedRawValue: "chrome") == .chromium)
        #expect(BrowserEngineDefaultChoice(persistedRawValue: "AUTO") == .auto)
        #expect(BrowserEngineDefaultChoice(persistedRawValue: "unknown-engine") == .auto)
    }
}
