import Testing
@testable import CmuxChromium

struct ChromiumKeyTranslationTests {
    private let translation = ChromiumKeyTranslation()

    @Test func mapsEditingAndNavigationKeys() {
        #expect(translation.windowsKeyCode(macKeyCode: 0x24, characters: "\r") == 0x0D)
        #expect(translation.windowsKeyCode(macKeyCode: 0x33, characters: "\u{7F}") == 0x08)
        #expect(translation.windowsKeyCode(macKeyCode: 0x35, characters: "\u{1B}") == 0x1B)
        #expect(translation.windowsKeyCode(macKeyCode: 0x7B, characters: "\u{F702}") == 0x25)
        #expect(translation.windowsKeyCode(macKeyCode: 0x7E, characters: "\u{F700}") == 0x26)
        #expect(translation.windowsKeyCode(macKeyCode: 0x7C, characters: "\u{F703}") == 0x27)
        #expect(translation.windowsKeyCode(macKeyCode: 0x7D, characters: "\u{F701}") == 0x28)
    }

    @Test func derivesAlphanumericCodesFromCharacters() {
        #expect(translation.windowsKeyCode(macKeyCode: 0x00, characters: "a") == 0x41)
        #expect(translation.windowsKeyCode(macKeyCode: 0x00, characters: "A") == 0x41)
        #expect(translation.windowsKeyCode(macKeyCode: 0x06, characters: "z") == 0x5A)
        #expect(translation.windowsKeyCode(macKeyCode: 0x1D, characters: "0") == 0x30)
        #expect(translation.windowsKeyCode(macKeyCode: 0x19, characters: "9") == 0x39)
    }

    @Test func unknownKeysFallBackToZero() {
        #expect(translation.windowsKeyCode(macKeyCode: 0x0A, characters: "§") == 0)
        #expect(translation.windowsKeyCode(macKeyCode: 0x0A, characters: nil) == 0)
    }

    @Test func printableTextPassesThrough() {
        #expect(translation.text(characters: "a", isCommandPressed: false) == "a")
        #expect(translation.text(characters: "\r", isCommandPressed: false) == "\r")
        #expect(translation.text(characters: "\t", isCommandPressed: false) == "\t")
    }

    @Test func nonPrintableTextIsSuppressed() {
        #expect(translation.text(characters: "\u{F702}", isCommandPressed: false) == "")
        #expect(translation.text(characters: "\u{1B}", isCommandPressed: false) == "")
        #expect(translation.text(characters: "\u{7F}", isCommandPressed: false) == "")
        #expect(translation.text(characters: nil, isCommandPressed: false) == "")
    }

    @Test func commandShortcutsSuppressText() {
        #expect(translation.text(characters: "c", isCommandPressed: true) == "")
    }
}
