import Foundation
import Testing
@testable import CmuxSettings

@Suite("AutoNamingLanguage")
struct AutoNamingLanguageTests {
    @Test func autoAndEmptyResolveToNil() {
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: "auto", preferredLanguages: ["ja-JP"]) == nil)
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: "AUTO", preferredLanguages: []) == nil)
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: "  ", preferredLanguages: ["ja"]) == nil)
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: nil, preferredLanguages: ["ja"]) == nil)
    }

    @Test func explicitTagPassesThrough() {
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: "ja", preferredLanguages: []) == "ja")
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: "zh-Hans", preferredLanguages: ["en"]) == "zh-Hans")
        // Whitespace is trimmed but the tag is otherwise verbatim.
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: "  en  ", preferredLanguages: []) == "en")
    }

    @Test func systemUsesFirstNonEmptyPreferredLanguage() {
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: "system", preferredLanguages: ["ja-JP", "en"]) == "ja-JP")
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: "SYSTEM", preferredLanguages: ["  ", "fr-FR"]) == "fr-FR")
    }

    @Test func systemWithNoPreferredLanguageFallsBackToAuto() {
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: "system", preferredLanguages: []) == nil)
        #expect(AutoNamingLanguage.resolvedLanguageTag(setting: "system", preferredLanguages: ["   "]) == nil)
    }
}
