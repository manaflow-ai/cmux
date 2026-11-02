import CmuxCore
import Testing

@Suite("Panel badge text")
struct PanelBadgeTextTests {
    @Test func admitsEmojiAndShortText() {
        #expect(PanelBadgeText("🦀")?.value == "🦀")
        #expect(PanelBadgeText("[work]")?.value == "[work]")
        #expect(PanelBadgeText("  💼  ")?.value == "💼")
    }

    @Test func titledPutsBadgeInFront() {
        #expect(PanelBadgeText("🦀")?.titled("cargo build") == "🦀 cargo build")
    }

    @Test func countsMultiScalarEmojiAsOneCharacter() {
        let family = "👩‍👩‍👧‍👦"
        let flag = "🇺🇸"
        let badge = String(repeating: family, count: 8) + String(repeating: flag, count: 8)
        #expect(PanelBadgeText(badge)?.value == badge)
    }

    @Test func rejectsEmptyAndOverlongText() {
        #expect(PanelBadgeText("") == nil)
        #expect(PanelBadgeText("   ") == nil)
        #expect(PanelBadgeText(String(repeating: "x", count: PanelBadgeText.maximumCharacters)) != nil)
        #expect(PanelBadgeText(String(repeating: "x", count: PanelBadgeText.maximumCharacters + 1)) == nil)
    }

    @Test func boundsScalarsInsideOneCharacter() {
        let atLimit = "e" + String(repeating: "\u{0301}", count: PanelBadgeText.maximumScalars - 1)
        #expect(atLimit.count == 1)
        #expect(PanelBadgeText(atLimit) != nil)
        #expect(PanelBadgeText(atLimit + "\u{0301}") == nil)
        let huge = "e" + String(repeating: "\u{0301}", count: 1_000_000)
        #expect(PanelBadgeText(huge) == nil)
    }

    @Test func rejectsInvisibleOnlyText() {
        #expect(PanelBadgeText("\u{200B}") == nil)
        #expect(PanelBadgeText("\u{200D}\u{FE0F}") == nil)
        #expect(PanelBadgeText("\u{3000}\u{2060}") == nil)
    }

    @Test(arguments: [
        0x00, 0x09, 0x0A, 0x1F, 0x7F, 0x80, 0x85, 0x9F,
        0x2028, 0x2029, 0x202A, 0x202E, 0x2066, 0x2069,
    ] as [UInt32])
    func rejectsControlAndBidiScalarsAtRangeEdges(_ value: UInt32) throws {
        let scalar = try #require(Unicode.Scalar(value))
        #expect(PanelBadgeText("a\(Character(scalar))b") == nil)
    }

    @Test(arguments: [0x20, 0xA0, 0x2027, 0x202F, 0x2065, 0x206A] as [UInt32])
    func admitsScalarsJustOutsideRejectedRanges(_ value: UInt32) throws {
        let scalar = try #require(Unicode.Scalar(value))
        #expect(PanelBadgeText("a\(Character(scalar))b") != nil)
    }
}
