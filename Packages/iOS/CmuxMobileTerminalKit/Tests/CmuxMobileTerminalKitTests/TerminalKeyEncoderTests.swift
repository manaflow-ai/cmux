import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalKeyEncoder byte tables")
struct TerminalKeyEncoderTests {
    @Test("special keys encode to exact VT bytes", arguments: [
        (TerminalSpecialKey.upArrow, TerminalKeyModifier(), [0x1B, 0x5B, 0x41]),
        (.downArrow, [], [0x1B, 0x5B, 0x42]),
        (.rightArrow, [], [0x1B, 0x5B, 0x43]),
        (.leftArrow, [], [0x1B, 0x5B, 0x44]),
        (.home, [], [0x1B, 0x5B, 0x48]),
        (.end, [], [0x1B, 0x5B, 0x46]),
        (.pageUp, [], [0x1B, 0x5B, 0x35, 0x7E]),
        (.pageDown, [], [0x1B, 0x5B, 0x36, 0x7E]),
        (.delete, [], [0x1B, 0x5B, 0x33, 0x7E]),
        (.escape, [], [0x1B]),
        (.tab, [], [0x09]),
        (.tab, [.shift], [0x1B, 0x5B, 0x5A]),
        (.leftArrow, [.alternate], [0x1B, 0x62]),
        (.rightArrow, [.alternate], [0x1B, 0x66]),
        (.delete, [.alternate], [0x1B, 0x7F]),
    ] as [(TerminalSpecialKey, TerminalKeyModifier, [UInt8])])
    func specialKeys(key: TerminalSpecialKey, modifiers: TerminalKeyModifier, expected: [UInt8]) {
        #expect(TerminalKeyEncoder.encode(specialKey: key, modifiers: modifiers) == Data(expected))
    }

    @Test("undefined special-key combinations return nil")
    func undefinedSpecial() {
        #expect(TerminalKeyEncoder.encode(specialKey: .upArrow, modifiers: [.alternate]) == nil)
        #expect(TerminalKeyEncoder.encode(specialKey: .home, modifiers: [.control]) == nil)
        #expect(TerminalKeyEncoder.encode(specialKey: .escape, modifiers: [.shift]) == nil)
    }

    @Test("extraneous modifier bits are masked before lookup")
    func masksUnsupportedBits() {
        // A high bit outside the supported set must not change the encoding.
        let stray = TerminalKeyModifier(rawValue: 1 << 20)
        #expect(TerminalKeyEncoder.encode(specialKey: .upArrow, modifiers: stray) == Data([0x1B, 0x5B, 0x41]))
    }

    @Test("control letters map to control bytes", arguments: [
        ("a", UInt8(0x01)), ("c", 0x03), ("d", 0x04), ("z", 0x1A),
        ("A", 0x01), ("Z", 0x1A), ("[", 0x1B), ("]", 0x1D), ("\\", 0x1C),
    ])
    func controlLetters(input: String, expected: UInt8) {
        #expect(TerminalKeyEncoder.encode(character: input, modifiers: [.control]) == Data([expected]))
    }

    @Test("control numeric and symbolic aliases", arguments: [
        (" ", UInt8(0x00)), ("2", 0x00), ("3", 0x1B), ("4", 0x1C),
        ("5", 0x1D), ("6", 0x1E), ("7", 0x1F), ("/", 0x1F), ("?", 0x7F),
    ])
    func controlAliases(input: String, expected: UInt8) {
        #expect(TerminalKeyEncoder.controlCharacter(for: input) == Data([expected]))
    }

    @Test("control+shift still resolves the control byte")
    func controlShift() {
        #expect(TerminalKeyEncoder.encode(character: "@", modifiers: [.control, .shift]) == Data([0x00]))
        #expect(TerminalKeyEncoder.encode(character: "^", modifiers: [.control, .shift]) == Data([0x1E]))
        #expect(TerminalKeyEncoder.encode(character: "_", modifiers: [.control, .shift]) == Data([0x1F]))
        #expect(TerminalKeyEncoder.encode(character: "?", modifiers: [.control, .shift]) == Data([0x7F]))
    }

    @Test("unmodified character returns nil (keyboard inserts it directly)")
    func unmodifiedCharacterNil() {
        #expect(TerminalKeyEncoder.encode(character: "a", modifiers: []) == nil)
    }

    @Test("alt-prefixed text prepends ESC")
    func altPrefixed() {
        #expect(TerminalKeyEncoder.altPrefixed("b") == Data([0x1B, 0x62]))
        #expect(TerminalKeyEncoder.altPrefixed("hi") == Data([0x1B, 0x68, 0x69]))
        #expect(TerminalKeyEncoder.altPrefixed("") == nil)
    }

    @Test("command readline shortcuts", arguments: [
        ("a", UInt8(0x01)), ("e", 0x05), ("k", 0x0B), ("u", 0x15),
        ("w", 0x17), ("l", 0x0C), ("c", 0x03), ("d", 0x04),
        ("A", 0x01), ("E", 0x05),
    ])
    func commandReadline(input: String, expected: UInt8) {
        #expect(TerminalKeyEncoder.commandReadline(for: input) == Data([expected]))
    }

    @Test("unmapped command readline returns nil")
    func commandReadlineNil() {
        #expect(TerminalKeyEncoder.commandReadline(for: "z") == nil)
        #expect(TerminalKeyEncoder.commandReadline(for: "ab") == nil)
    }
}
