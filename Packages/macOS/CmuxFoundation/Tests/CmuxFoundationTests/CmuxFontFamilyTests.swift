import AppKit
import Testing
@testable import CmuxFoundation

@Suite("cmux font family resolution")
struct CmuxFontFamilyTests {
    @Test("Empty values resolve to the system fallback")
    func emptyValuesUseSystemFont() {
        #expect(CmuxFontFamily(rawValue: " \n\t") == nil)
        let font = CmuxFontResolver.appKitFont(
            family: " \n\t",
            size: 13,
            weight: .regular,
            monospaced: false
        )
        #expect(font.pointSize == 13)
    }

    @Test("Installed family names are retained by AppKit resolution")
    func installedFamilyResolves() throws {
        let family = "Georgia"
        _ = try #require(NSFont(name: family, size: 13))
        let font = CmuxFontResolver.appKitFont(
            family: family,
            size: 13,
            weight: .regular,
            monospaced: false
        )
        #expect(font.familyName?.caseInsensitiveCompare(family) == .orderedSame)
    }

    @Test("Unknown family names fall back without blanking the text")
    func unknownFamilyFallsBack() {
        let font = CmuxFontResolver.appKitFont(
            family: "cmux-font-family-that-is-not-installed",
            size: 13,
            weight: .regular,
            monospaced: false
        )
        #expect(font.pointSize == 13)
        #expect(font.familyName?.caseInsensitiveCompare("cmux-font-family-that-is-not-installed") != .orderedSame)
    }

    @Test("An explicit family overrides the default metadata font design")
    func explicitFamilyOverridesDefaultMonospaceDesign() {
        let font = CmuxFontResolver.appKitFont(family: "Georgia", size: 13, monospaced: true)

        #expect(font.familyName == "Georgia")
    }

    @Test("Differently cased family names share a valid resolution")
    func caseVariantsDoNotPoisonCache() {
        for family in ["menlo", "MENLO", "Menlo"] {
            let font = CmuxFontResolver.appKitFont(family: family, size: 13.25)

            #expect(font.familyName == "Menlo")
        }
    }
}
