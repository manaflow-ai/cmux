import Testing
@testable import CmuxSettings

@Suite("VS Code display locale")
struct AppLanguageVSCodeLocaleTests {
    @Test func systemLanguageUsesTraditionalChineseScript() {
        #expect(AppLanguage.system.resolvedVSCodeLocale(preferredLanguages: ["zh-Hant-HK"]) == "zh-tw")
    }
    @Test func systemLanguageUsesChineseRegion() {
        #expect(AppLanguage.system.resolvedVSCodeLocale(preferredLanguages: ["zh-TW"]) == "zh-tw")
        #expect(AppLanguage.system.resolvedVSCodeLocale(preferredLanguages: ["zh-CN"]) == "zh-cn")
    }
    @Test func systemLanguageDropsRegionForSupportedLanguage() {
        #expect(AppLanguage.system.resolvedVSCodeLocale(preferredLanguages: ["de-DE"]) == "de")
        #expect(AppLanguage.system.resolvedVSCodeLocale(preferredLanguages: ["pt_BR"]) == "pt-br")
    }
    @Test func explicitLanguageTakesPriorityOverSystem() {
        #expect(AppLanguage.ja.resolvedVSCodeLocale(preferredLanguages: ["de-DE"]) == "ja")
        #expect(AppLanguage.zhHans.resolvedVSCodeLocale(preferredLanguages: ["en-US"]) == "zh-cn")
    }
    @Test func unsupportedOrMissingLanguageUsesExplicitEnglish() {
        #expect(AppLanguage.ar.resolvedVSCodeLocale(preferredLanguages: ["de-DE"]) == "en")
        #expect(AppLanguage.system.resolvedVSCodeLocale(preferredLanguages: ["vi-VN"]) == "en")
        #expect(AppLanguage.system.resolvedVSCodeLocale(preferredLanguages: []) == "en")
    }
}
