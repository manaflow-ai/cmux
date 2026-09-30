import Foundation
import Testing
@testable import CmuxNextBrowser

/// Chrome on macOS takes its UI language and Accept-Language from the
/// system's preferred languages, never from LANG/LC_* (a clean `env -i`
/// launch has none) and never from an alphabetical fallback.
@Suite struct CEFLocaleTests {
    /// `.lproj` names of the pinned CEF framework (a subset).
    static let lproj = [
        "ar.lproj", "de.lproj", "en.lproj", "en_GB.lproj", "en_GB_FEMININE.lproj", "en_XA.lproj",
        "es.lproj", "es_419.lproj", "fr.lproj", "ja.lproj", "ja_NEUTER.lproj", "ko.lproj", "nb.lproj",
        "pt_BR.lproj", "pt_PT.lproj", "ru.lproj", "zh_CN.lproj", "zh_TW.lproj", "locale.pak",
    ]
    static var available: Set<String> { CEFLocale.available(lprojNames: lproj) }

    @Test func availableLocalesUseChromiumNames() {
        let names = Self.available
        #expect(names.contains("en-US"))
        #expect(names.contains("en-GB"))
        #expect(names.contains("es-419"))
        #expect(names.contains("zh-TW"))
        #expect(names.contains("ja"))
        // Gendered variants and pseudo-locales are not UI locales.
        #expect(!names.contains { $0.contains("FEMININE") || $0.contains("NEUTER") || $0.contains("XA") })
        #expect(!names.contains("locale.pak"))
    }

    @Test func englishUserGetsEnglish() {
        let result = CEFLocale.resolve(preferredLanguages: ["en-US", "zh-Hant-US", "ja-US", "ko-US"], available: Self.available)
        #expect(result.locale == "en-US")
        #expect(result.acceptLanguages == "en-US,en,zh-TW,zh,ja,ko")
    }

    @Test func japaneseFirstGetsJapanese() {
        let result = CEFLocale.resolve(preferredLanguages: ["ja-JP", "en-JP"], available: Self.available)
        #expect(result.locale == "ja")
        #expect(result.acceptLanguages == "ja,en-US,en")
    }

    @Test func chineseScriptsMapToChromiumRegions() {
        #expect(CEFLocale.resolve(preferredLanguages: ["zh-Hans-CN"], available: Self.available).locale == "zh-CN")
        #expect(CEFLocale.resolve(preferredLanguages: ["zh-Hant-TW"], available: Self.available).locale == "zh-TW")
        #expect(CEFLocale.resolve(preferredLanguages: ["zh-Hant-HK"], available: Self.available).locale == "zh-TW")
    }

    @Test func regionalVariantsFollowChrome() {
        #expect(CEFLocale.resolve(preferredLanguages: ["en-GB"], available: Self.available).locale == "en-GB")
        #expect(CEFLocale.resolve(preferredLanguages: ["en-AU"], available: Self.available).locale == "en-GB")
        #expect(CEFLocale.resolve(preferredLanguages: ["pt-PT"], available: Self.available).locale == "pt-PT")
        #expect(CEFLocale.resolve(preferredLanguages: ["pt"], available: Self.available).locale == "pt-BR")
        #expect(CEFLocale.resolve(preferredLanguages: ["es-MX"], available: Self.available).locale == "es-419")
        #expect(CEFLocale.resolve(preferredLanguages: ["es-ES"], available: Self.available).locale == "es")
        #expect(CEFLocale.resolve(preferredLanguages: ["no"], available: Self.available).locale == "nb")
    }

    /// A language Chromium has no pak for (Khmer, which the app ships) moves
    /// on to the next preferred language, then to en-US. Never the first
    /// locale in alphabetical order (ar).
    @Test func missingPakFallsToNextPreferredThenEnglish() {
        let next = CEFLocale.resolve(preferredLanguages: ["km-KH", "de-DE"], available: Self.available)
        #expect(next.locale == "de")
        #expect(next.acceptLanguages == "km-KH,km,de")
        let none = CEFLocale.resolve(preferredLanguages: ["km-KH"], available: Self.available)
        #expect(none.locale == "en-US")
        let empty = CEFLocale.resolve(preferredLanguages: [], available: Self.available)
        #expect(empty.locale == "en-US")
        #expect(empty.acceptLanguages == "en-US,en")
    }

    @Test func acceptListHasNoDuplicates() {
        let result = CEFLocale.resolve(preferredLanguages: ["en-US", "en-GB", "en"], available: Self.available)
        #expect(result.acceptLanguages == "en-US,en,en-GB")
    }
}
