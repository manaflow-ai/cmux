import SwiftUI
import Testing
@testable import CmuxFoundation

@Suite("SwiftUI sidebar font family resolution")
struct CmuxSwiftUIFontFamilyTests {
    @Test("SwiftUI uses the resolved PostScript name", arguments: ["Menlo", "menlo", "MENLO"])
    func resolvesPostScriptName(family: String) {
        let font = CmuxFontResolver.swiftUIFont(family: family, size: 13, weight: .semibold)

        #expect(font == Font.custom("Menlo-Regular", size: 13).weight(.semibold))
    }

    @Test("SwiftUI invalid names retain the system design")
    func invalidFamilyPreservesSystemDesign() {
        let font = CmuxFontResolver.swiftUIFont(
            family: "cmux-font-family-that-is-not-installed",
            size: 13,
            weight: .medium,
            design: .rounded
        )

        #expect(font == Font.system(size: 13, weight: .medium, design: .rounded))
    }
}
