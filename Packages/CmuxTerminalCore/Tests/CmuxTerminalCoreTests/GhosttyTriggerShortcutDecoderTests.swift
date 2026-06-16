import Testing
@testable import CmuxTerminalCore

@Suite struct GhosttyTriggerShortcutDecoderTests {
    private let decoder = GhosttyTriggerShortcutDecoder()
    private let command = GhosttyModifierMask(rawValue: GhosttyModifierMask.commandBit)

    @Test func physicalArrowKeysMapToArrowGlyphs() {
        let left = decoder.decode(
            GhosttyTriggerInput(tag: .physical(.arrowLeft), modifiers: command)
        )
        #expect(left == GhosttyTriggerShortcut(key: "←", command: true, shift: false, option: false, control: false))

        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(.arrowRight), modifiers: command))?.key == "→")
        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(.arrowUp), modifiers: command))?.key == "↑")
        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(.arrowDown), modifiers: command))?.key == "↓")
    }

    @Test func physicalLetterAndPunctuationGlyphs() {
        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(.k), modifiers: command))?.key == "k")
        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(.digit7), modifiers: command))?.key == "7")
        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(.bracketLeft), modifiers: command))?.key == "[")
        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(.backslash), modifiers: command))?.key == "\\")
        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(.backquote), modifiers: command))?.key == "`")
    }

    @Test func allModifierBitsAreDecoded() {
        let allMods = GhosttyModifierMask(
            rawValue: GhosttyModifierMask.commandBit
                | GhosttyModifierMask.shiftBit
                | GhosttyModifierMask.optionBit
                | GhosttyModifierMask.controlBit
        )
        let result = decoder.decode(GhosttyTriggerInput(tag: .physical(.a), modifiers: allMods))
        #expect(result == GhosttyTriggerShortcut(key: "a", command: true, shift: true, option: true, control: true))
    }

    @Test func unmappedPhysicalKeyReturnsNil() {
        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(nil), modifiers: command)) == nil)
    }

    @Test func catchAllReturnsNil() {
        #expect(decoder.decode(GhosttyTriggerInput(tag: .catchAll, modifiers: command)) == nil)
    }

    @Test func unicodeScalarIsLowercased() {
        let scalar = Unicode.Scalar("K")
        let result = decoder.decode(GhosttyTriggerInput(tag: .unicode(scalar), modifiers: command))
        #expect(result?.key == "k")
    }

    @Test func invalidUnicodeScalarReturnsNil() {
        #expect(decoder.decode(GhosttyTriggerInput(tag: .unicode(nil), modifiers: command)) == nil)
    }

    @Test func triggerWithNoModifiersReturnsNil() {
        let none = GhosttyModifierMask(rawValue: 0)
        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(.a), modifiers: none)) == nil)
    }

    @Test func capsAndNumLockOnlyAreTreatedAsEmpty() {
        // GHOSTTY_MODS_CAPS (1 << 4) and GHOSTTY_MODS_NUM (1 << 5) are not mapped
        // modifiers, so a trigger carrying only those is rejected as empty.
        let capsAndNum = GhosttyModifierMask(rawValue: (1 << 4) | (1 << 5))
        #expect(capsAndNum.isEmpty)
        #expect(decoder.decode(GhosttyTriggerInput(tag: .physical(.a), modifiers: capsAndNum)) == nil)
    }

    @Test func everyPhysicalKeyGlyphIsNonEmpty() {
        for key in GhosttyTriggerPhysicalKey.allCases {
            #expect(!key.glyph.isEmpty)
            let result = decoder.decode(GhosttyTriggerInput(tag: .physical(key), modifiers: command))
            #expect(result?.key == key.glyph)
        }
    }
}
