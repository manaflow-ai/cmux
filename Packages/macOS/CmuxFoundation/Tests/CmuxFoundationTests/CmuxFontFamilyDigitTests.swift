import AppKit
import Testing
@testable import CmuxFoundation

@MainActor
@Suite("Sidebar font family numeric metrics")
struct CmuxFontFamilyDigitTests {
    @Test("Fonts with tabular digits retain equal advances", arguments: ["Helvetica", "Menlo"])
    func numericLabelsUseTabularDigits(family: String) throws {
        _ = try #require(NSFont(name: family, size: 13))
        let font = CmuxFontResolver.appKitFont(
            family: family,
            size: 13,
            weight: .medium,
            monospacedDigits: true
        )
        let advances = "0123456789".map { digit in
            (String(digit) as NSString).size(withAttributes: [.font: font]).width
        }

        let minimum = try #require(advances.min())
        let maximum = try #require(advances.max())
        #expect(maximum - minimum < 0.01)
    }

    @Test("Families with tabular digits do not switch to a system face", arguments: ["Helvetica", "Menlo"])
    func supportedFamilyIsPreserved(family: String) {
        let font = CmuxFontResolver.appKitFont(family: family, size: 13, monospacedDigits: true)

        #expect(font.familyName == family)
    }

    @Test("Unsupported numeric features do not replace an installed family")
    func unsupportedNumericFeaturePreservesFamily() {
        let font = CmuxFontResolver.appKitFont(family: "Georgia", size: 13, monospacedDigits: true)

        #expect(font.familyName == "Georgia")
    }

    @Test("Non-numeric text keeps a proportional family")
    func regularTextRetainsFamily() {
        let font = CmuxFontResolver.appKitFont(family: "Georgia", size: 13)

        #expect(font.familyName == "Georgia")
    }
}
